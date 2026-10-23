package auth

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"pointverse/server/internal/database"
)

func testDatabase(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not configured")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	admin, err := database.Open(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	schema := pgx.Identifier{fmt.Sprintf("pointverse_auth_test_%d", time.Now().UnixNano())}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		if _, err := admin.Exec(cleanup, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Error(err)
		}
		admin.Close()
	})
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if err := database.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	return pool
}
func request(t *testing.T, handler http.Handler, method, path, body, token string, code int) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != code {
		t.Fatalf("%s %s: got %d, want %d; %s", method, path, w.Code, code, w.Body.String())
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("authentication response can be cached")
	}
	return w
}
func decode[T any](t *testing.T, w *httptest.ResponseRecorder) T {
	t.Helper()
	var value T
	if err := json.Unmarshal(w.Body.Bytes(), &value); err != nil {
		t.Fatal(err)
	}
	return value
}
func loginJSON(raw, challenge string) string {
	v := map[string]string{"id_token": raw}
	if challenge != "" {
		v["challenge_id"] = challenge
	}
	b, _ := json.Marshal(v)
	return string(b)
}
func TestLoginLifecycleIntegration(t *testing.T) {
	pool := testDatabase(t)
	f := newFixture(t)
	store := NewStore(pool)
	mux := http.NewServeMux()
	NewHandler(store, f.providers).Register(mux)
	raw := f.token(t, "google", "google-user", "", nil)
	first := decode[Session](t, request(t, mux, "POST", "/v1/auth/google", loginJSON(raw, ""), "", 200))
	if !validSecret(first.AccessToken) || first.User.ID == "" || !first.User.Identities[0].EmailVerified {
		t.Fatal("invalid session")
	}
	request(t, mux, "GET", "/v1/auth/me", "", "", 401)
	user := decode[User](t, request(t, mux, "GET", "/v1/auth/me", "", first.AccessToken, 200))
	if user.ID != first.User.ID {
		t.Fatal("session owner mismatch")
	}
	// Token fingerprints and session credentials must be stored as hashes.
	var exists bool
	err := pool.QueryRow(context.Background(), "SELECT EXISTS(SELECT 1 FROM auth_sessions WHERE token_hash=$1)", digest(first.AccessToken)).Scan(&exists)
	if err != nil || !exists {
		t.Fatalf("session hash missing: %v", err)
	}
	request(t, mux, "POST", "/v1/auth/google", loginJSON(raw, ""), "", 401)
	raw2 := f.token(t, "google", "google-user", "", func(c map[string]any) { c["jti"] = "second" })
	second := decode[Session](t, request(t, mux, "POST", "/v1/auth/google", loginJSON(raw2, ""), "", 200))
	if first.User.ID != second.User.ID {
		t.Fatal("repeat login duplicated account")
	}
	request(t, mux, "POST", "/v1/auth/logout", "", first.AccessToken, 204)
	request(t, mux, "POST", "/v1/auth/logout", "", first.AccessToken, 204)
	request(t, mux, "GET", "/v1/auth/me", "", first.AccessToken, 401)
	request(t, mux, "GET", "/v1/auth/me", "", second.AccessToken, 200)
	if _, err := pool.Exec(context.Background(), "UPDATE auth_sessions SET expires_at=now()-interval '1 second' WHERE token_hash=$1", digest(second.AccessToken)); err != nil {
		t.Fatal(err)
	}
	request(t, mux, "GET", "/v1/auth/me", "", second.AccessToken, 401)
	challenge := decode[Challenge](t, request(t, mux, "POST", "/v1/auth/apple/challenge", "", "", 201))
	appleRaw := f.token(t, "apple", "apple-user", challenge.Nonce, nil)
	// A wrong nonce must not consume the valid challenge.
	wrong := f.token(t, "apple", "apple-user", "wrong-nonce", nil)
	request(t, mux, "POST", "/v1/auth/apple", loginJSON(wrong, challenge.ID), "", 401)
	apple := decode[Session](t, request(t, mux, "POST", "/v1/auth/apple", loginJSON(appleRaw, challenge.ID), "", 200))
	if apple.User.ID == first.User.ID {
		t.Fatal("accounts merged using email")
	}
	request(t, mux, "POST", "/v1/auth/apple", loginJSON(appleRaw, challenge.ID), "", 401)
	challenge2 := decode[Challenge](t, request(t, mux, "POST", "/v1/auth/apple/challenge", "", "", 201))
	if _, err := pool.Exec(context.Background(), "UPDATE apple_login_challenges SET expires_at=now()-interval '1 second' WHERE id_hash=$1", digest(challenge2.ID)); err != nil {
		t.Fatal(err)
	}
	request(t, mux, "POST", "/v1/auth/apple", loginJSON(f.token(t, "apple", "apple-user", challenge2.Nonce, nil), challenge2.ID), "", 401)
	request(t, mux, "POST", "/v1/auth/google", `{"id_token":"bad","user_id":"spoofed"}`, "", 400)
	request(t, mux, "POST", "/v1/auth/google", `{"id_token":"bad"} {}`, "", 400)
	request(t, mux, "POST", "/v1/auth/google", `{"id_token":"`+strings.Repeat("x", 21000)+`"}`, "", 400)
}
func TestConcurrentLoginIntegration(t *testing.T) {
	pool := testDatabase(t)
	store := NewStore(pool)
	base := Identity{Provider: "google", Subject: "concurrent", ExpiresAt: time.Now().Add(time.Hour)}
	results := make(chan Session, 4)
	errs := make(chan error, 4)
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			identity := base
			identity.TokenHash = sha256.Sum256([]byte(fmt.Sprint(i)))
			s, err := store.Login(context.Background(), identity, "")
			results <- s
			errs <- err
		}(i)
	}
	wg.Wait()
	close(results)
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	id := ""
	for s := range results {
		if id == "" {
			id = s.User.ID
		}
		if s.User.ID != id {
			t.Fatal("concurrent first login duplicated users")
		}
	}
	var users int
	if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM users").Scan(&users); err != nil || users != 1 {
		t.Fatalf("users=%d err=%v", users, err)
	}
}
func TestRateLimitAndDisabledProviders(t *testing.T) {
	mux := http.NewServeMux()
	NewHandler(nil, NewProviders(context.Background(), nil, nil)).Register(mux)
	request(t, mux, "GET", "/v1/auth/providers", "", "", 200)
	for i := 0; i < 20; i++ {
		request(t, mux, "POST", "/v1/auth/google", `{}`, "", 503)
	}
	request(t, mux, "POST", "/v1/auth/google", `{}`, "", 429)
	l := &limiter{entries: map[string]bucket{}}
	now := time.Now()
	for i := 0; i < 20; i++ {
		if !l.allow("ip", now) {
			t.Fatal("early limit")
		}
	}
	if l.allow("ip", now) {
		t.Fatal("limit not enforced")
	}
	if !l.allow("ip", now.Add(time.Minute)) {
		t.Fatal("limit never expires")
	}
	for i := 0; i < 4096; i++ {
		l.entries[fmt.Sprint(i)] = bucket{start: now}
	}
	if l.allow("unknown", now) {
		t.Fatal("limiter memory bound exceeded")
	}
}
