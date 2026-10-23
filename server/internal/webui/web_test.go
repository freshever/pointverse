package webui

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestEmbeddedAccountPage(t *testing.T) {
	mux := http.NewServeMux()
	Register(mux)
	for _, path := range []string{"/account/", "/account/app.js", "/account/style.css"} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 200 {
			t.Fatalf("%s status=%d", path, w.Code)
		}
		if !strings.Contains(w.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") {
			t.Fatal("missing browser protection")
		}
		if w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("account page cacheable")
		}
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/", nil))
	if w.Code != 302 || w.Header().Get("Location") != "/account/" {
		t.Fatal("missing root redirect")
	}
}

func TestVersionedIconCaching(t *testing.T) {
	mux := http.NewServeMux()
	Register(mux)
	for _, path := range []string{"/account/app-icon-v1.png", "/account/favicon-v1.png", "/account/apple-touch-icon-v1.png"} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "image/png" {
			t.Fatalf("%s: status=%d type=%s", path, w.Code, w.Header().Get("Content-Type"))
		}
		if w.Header().Get("Cache-Control") != "public, max-age=31536000, immutable" {
			t.Fatalf("%s: missing versioned icon cache policy", path)
		}
	}
}
