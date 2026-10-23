package cloud

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"pointverse/server/internal/auth"
	"pointverse/server/internal/database"
)

func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not configured")
	}
	ctx := context.Background()
	admin, err := database.Open(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	schema := pgx.Identifier{fmt.Sprintf("cloud_test_%d", time.Now().UnixNano())}.Sanitize()
	if _, err = admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, err := admin.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE")
		if err != nil {
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
	if err = database.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	return pool
}
func call(t *testing.T, h http.Handler, method, path, token string, body []byte, status int) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, bytes.NewReader(body))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != status {
		t.Fatalf("%s %s got %d want %d: %s", method, path, w.Code, status, w.Body.String())
	}
	return w
}
func TestCloudUploadOwnershipAndVersionsIntegration(t *testing.T) {
	pool := testPool(t)
	store := auth.NewStore(pool)
	providers := auth.NewProviders(context.Background(), nil, nil)
	authentication := auth.NewHandler(store, providers)
	root := t.TempDir()
	cloud, err := New(pool, root, authentication)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	authentication.Register(mux)
	cloud.Register(mux)
	first, err := store.RegisterEmail(context.Background(), "first@example.invalid", "unused-test-hash")
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.RegisterEmail(context.Background(), "second@example.invalid", "unused-test-hash")
	if err != nil {
		t.Fatal(err)
	}
	assetData := []byte("test original audio")
	sum := sha256.Sum256(assetData)
	hash := hex.EncodeToString(sum[:])
	pointID := "9110f7e3-fd62-4b14-9440-2ebc679dd835"
	manifest := Manifest{FormatVersion: 1, PointID: pointID, Revision: 1, Title: "My first idea", Preview: "original text", CreatedAt: 1700000000, Assets: []Asset{{ID: "8b8c01d0-231e-46fa-b80f-ac906824f27c", SHA256: hash, ByteCount: int64(len(assetData)), Kind: "audio"}}, Payload: json.RawMessage(`{"points":[{"id":"` + pointID + `","head_revision":1}],"messages":[{"user_text":"original text"}]}`)}
	raw, _ := json.Marshal(manifest)
	call(t, mux, "GET", "/v1/sync/points", "", nil, 401)
	call(t, mux, "POST", "/v1/sync/points", first.AccessToken, raw, 409)
	call(t, mux, "PUT", "/v1/sync/assets/"+hash, first.AccessToken, []byte("wrong bytes"), 400)
	call(t, mux, "GET", "/v1/sync/assets/"+hash, first.AccessToken, nil, 404)
	call(t, mux, "PUT", "/v1/sync/assets/"+hash, first.AccessToken, assetData, 201)
	call(t, mux, "HEAD", "/v1/sync/assets/"+hash, first.AccessToken, nil, 200)
	call(t, mux, "GET", "/v1/sync/assets/"+hash, second.AccessToken, nil, 404)
	var before struct {
		Items []Version `json:"items"`
	}
	w := call(t, mux, "GET", "/v1/sync/points", first.AccessToken, nil, 200)
	if err = json.Unmarshal(w.Body.Bytes(), &before); err != nil || len(before.Items) != 0 {
		t.Fatal("incomplete upload visible")
	}
	w = call(t, mux, "POST", "/v1/sync/points", first.AccessToken, raw, 200)
	var version Version
	if err = json.Unmarshal(w.Body.Bytes(), &version); err != nil {
		t.Fatal(err)
	}
	call(t, mux, "POST", "/v1/sync/points", first.AccessToken, raw, 200)
	w = call(t, mux, "GET", "/v1/sync/points/"+pointID+"/versions/"+version.ManifestHash, first.AccessToken, nil, 200)
	if !bytes.Equal(w.Body.Bytes(), raw) {
		t.Fatal("snapshot changed during storage")
	}
	call(t, mux, "GET", "/v1/sync/points/"+pointID+"/versions/"+version.ManifestHash, second.AccessToken, nil, 404)
	downloaded := call(t, mux, "GET", "/v1/sync/assets/"+hash, first.AccessToken, nil, 200)
	if !bytes.Equal(downloaded.Body.Bytes(), assetData) {
		t.Fatal("original asset corrupted")
	}
	manifest.Title = "Different contents at the same revision"
	raw2, _ := json.Marshal(manifest)
	call(t, mux, "POST", "/v1/sync/points", first.AccessToken, raw2, 200)
	var count int
	if err = pool.QueryRow(context.Background(), "SELECT count(*) FROM cloud_point_versions WHERE user_id=$1", first.User.ID).Scan(&count); err != nil || count != 2 {
		t.Fatalf("expected two immutable versions: %d %v", count, err)
	}
	call(t, mux, "POST", "/v1/sync/points", second.AccessToken, raw, 409)
	call(t, mux, "PUT", "/v1/sync/assets/"+hash, second.AccessToken, assetData, 201)
	call(t, mux, "POST", "/v1/sync/points", second.AccessToken, raw, 200)
	// Browser cookies access only their own data and do not authorize native routes.
	request := httptest.NewRequest("GET", "/web/sync/points", nil)
	request.AddCookie(&http.Cookie{Name: "pointverse_session", Value: first.AccessToken})
	browser := httptest.NewRecorder()
	mux.ServeHTTP(browser, request)
	var listing struct {
		Items []Version `json:"items"`
		Next  string    `json:"next_cursor"`
	}
	if err = json.Unmarshal(browser.Body.Bytes(), &listing); err != nil || len(listing.Items) != 2 || listing.Items[0].AudioHash != hash {
		t.Fatalf("browser list: %s %v", browser.Body.String(), err)
	}
	request = httptest.NewRequest("GET", "/v1/sync/points", nil)
	request.AddCookie(&http.Cookie{Name: "pointverse_session", Value: first.AccessToken})
	browser = httptest.NewRecorder()
	mux.ServeHTTP(browser, request)
	if browser.Code != 401 {
		t.Fatal("browser cookie accepted on native API")
	}
	// Storage is reusable after process recreation.
	recreated, err := New(pool, root, authentication)
	if err != nil {
		t.Fatal(err)
	}
	mux2 := http.NewServeMux()
	recreated.Register(mux2)
	call(t, mux2, "GET", "/v1/sync/assets/"+hash, first.AccessToken, nil, 200)
	call(t, mux, "GET", "/v1/sync/points?cursor=malformed", first.AccessToken, nil, 400)
	call(t, mux, "PUT", "/v1/sync/assets/not-a-hash", first.AccessToken, assetData, 400)
	bad := strings.Replace(string(raw), `"head_revision":1`, `"head_revision":2`, 1)
	call(t, mux, "POST", "/v1/sync/points", first.AccessToken, []byte(bad), 400)
}
