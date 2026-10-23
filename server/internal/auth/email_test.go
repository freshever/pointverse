package auth

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestEmailAndPasswordValidation(t *testing.T) {
	email, ok := normalizeEmail("  Person+Notes@Example.COM ")
	if !ok || email != "person+notes@example.com" {
		t.Fatalf("normalization: %s %v", email, ok)
	}
	for _, email := range []string{"bad", "Person <a@example.com>", "a@example.com\r\n", "a b@example.com"} {
		// Outer whitespace is intentionally trimmed, while embedded header injection is rejected.
		if email == "a@example.com\r\n" {
			email = "a@ex\r\nample.com"
		}
		if _, ok := normalizeEmail(email); ok {
			t.Fatalf("invalid email accepted: %q", email)
		}
	}
	for _, password := range []string{"short", strings.Repeat("a", 129)} {
		if validPassword(password) {
			t.Fatal("invalid password length accepted")
		}
	}
	if !validPassword(strings.Repeat("点界", 6)) {
		t.Fatal("Unicode password rejected")
	}
	hash := hashPassword("a strong passphrase")
	if !verifyPassword("a strong passphrase", hash) || verifyPassword("wrong password", hash) {
		t.Fatal("password comparison failed")
	}
	if hash == hashPassword("a strong passphrase") {
		t.Fatal("password hashes do not use random salts")
	}
	if verifyPassword("a strong passphrase", "$argon2id$malformed") {
		t.Fatal("malformed hash accepted")
	}
}

func emailBody(email, password, confirmation string) string {
	value := map[string]string{"email": email, "password": password}
	if confirmation != "" {
		value["password_confirmation"] = confirmation
	}
	data, _ := json.Marshal(value)
	return string(data)
}
func browserRequest(t *testing.T, mux http.Handler, method, path, body string, cookie *http.Cookie, origin string, code int) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, "http://example.com"+path, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if origin != "" {
		r.Header.Set("Origin", origin)
	}
	if cookie != nil {
		r.AddCookie(cookie)
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != code {
		t.Fatalf("%s %s: got %d want %d: %s", method, path, w.Code, code, w.Body.String())
	}
	return w
}
func TestBrowserEmailLifecycleIntegration(t *testing.T) {
	pool := testDatabase(t)
	mux := http.NewServeMux()
	NewHandler(NewStore(pool), NewProviders(context.Background(), nil, nil)).Register(mux)
	password := "correct horse battery"
	body := emailBody("  Mailbox@Example.COM ", password, password)
	browserRequest(t, mux, "POST", "/web/auth/register", body, nil, "https://evil.example", 403)
	browserRequest(t, mux, "POST", "/web/auth/register", body, nil, "", 403)
	browserRequest(t, mux, "POST", "/web/auth/register", emailBody("a@example.com", password, "different"), nil, "http://example.com", 400)
	w := browserRequest(t, mux, "POST", "/web/auth/register", body, nil, "http://example.com", 201)
	if strings.Contains(w.Body.String(), "access_token") || strings.Contains(w.Body.String(), password) {
		t.Fatal("browser response leaked credential")
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 1 || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode || cookies[0].Path != "/web/" || cookies[0].MaxAge <= 0 {
		t.Fatalf("unsafe cookie: %v", cookies)
	}
	cookie := cookies[0]
	var registration struct {
		User User `json:"user"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &registration); err != nil {
		t.Fatal(err)
	}
	if registration.User.Identities[0].Email != "mailbox@example.com" || registration.User.Identities[0].EmailVerified {
		t.Fatal("email incorrectly normalized or marked verified")
	}
	var stored string
	if err := pool.QueryRow(context.Background(), "SELECT password_hash FROM email_credentials WHERE email='mailbox@example.com'").Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored == password || !verifyPassword(password, stored) {
		t.Fatal("password not safely persisted")
	}
	browserRequest(t, mux, "GET", "/web/auth/me", "", cookie, "", 200)
	browserRequest(t, mux, "POST", "/web/auth/register", body, nil, "http://example.com", 409)
	browserRequest(t, mux, "POST", "/web/auth/login", emailBody("mailbox@example.com", "wrong", ""), nil, "http://example.com", 401)
	browserRequest(t, mux, "POST", "/web/auth/login", emailBody("unknown@example.com", password, ""), nil, "http://example.com", 401)
	browserRequest(t, mux, "POST", "/web/auth/logout", "{}", cookie, "http://evil.example", 403)
	browserRequest(t, mux, "GET", "/web/auth/me", "", cookie, "", 200)
	w = browserRequest(t, mux, "POST", "/web/auth/logout", "{}", cookie, "http://example.com", 204)
	if len(w.Result().Cookies()) != 1 || w.Result().Cookies()[0].MaxAge != -1 {
		t.Fatal("logout did not clear cookie")
	}
	browserRequest(t, mux, "GET", "/web/auth/me", "", cookie, "", 401)
	login := browserRequest(t, mux, "POST", "/web/auth/login", emailBody("MAILBOX@example.com", password, ""), nil, "http://example.com", 200)
	var result struct {
		User User `json:"user"`
	}
	if err := json.Unmarshal(login.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.User.ID != registration.User.ID {
		t.Fatal("login created new user")
	}
	browserRequest(t, mux, "GET", "/web/auth/me", "", login.Result().Cookies()[0], "", 200)
	// API clients may obtain a bearer token without a browser cookie.
	session := decode[Session](t, request(t, mux, "POST", "/v1/auth/email/login", emailBody("mailbox@example.com", password, ""), "", 200))
	request(t, mux, "GET", "/v1/auth/me", "", session.AccessToken, 200)
	request(t, mux, "POST", "/v1/auth/email/register", `{"email":"bad","password":"long enough password"}`, "", 400)
	request(t, mux, "POST", "/v1/auth/email/register", `{"email":"a@example.com","password":"short","password_confirmation":"short"}`, "", 400)
	request(t, mux, "POST", "/v1/auth/email/register", `{"email":"a@example.com","password":"long enough password","password_confirmation":"long enough password","email_verified":true}`, "", 400)
}
func TestConcurrentEmailRegistrationIntegration(t *testing.T) {
	pool := testDatabase(t)
	store := NewStore(pool)
	hash := hashPassword("correct horse battery")
	results := make(chan error, 2)
	var group sync.WaitGroup
	for i := 0; i < 2; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			_, err := store.RegisterEmail(context.Background(), "same@example.com", hash)
			results <- err
		}()
	}
	group.Wait()
	close(results)
	success, duplicate := 0, 0
	for err := range results {
		if err == nil {
			success++
		} else if errors.Is(err, ErrEmailExists) {
			duplicate++
		} else {
			t.Fatal(err)
		}
	}
	if success != 1 || duplicate != 1 {
		t.Fatalf("success=%d duplicate=%d", success, duplicate)
	}
	var users int
	if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM users").Scan(&users); err != nil || users != 1 {
		t.Fatalf("orphan users: %d %v", users, err)
	}
	f := newFixture(t)
	identity, err := f.providers.Verify(context.Background(), "google", f.token(t, "google", "google-user", "", nil))
	if err != nil {
		t.Fatal(err)
	}
	oauth, err := store.Login(context.Background(), identity, "")
	if err != nil {
		t.Fatal(err)
	}
	email, err := store.LoginEmail(context.Background(), "same@example.com", "correct horse battery")
	if err != nil {
		t.Fatal(err)
	}
	if oauth.User.ID == email.User.ID {
		t.Fatal("email automatically merged with OAuth account")
	}
}
