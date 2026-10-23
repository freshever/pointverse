package httpapi

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestTrustedProxy(t *testing.T) {
	for _, tc := range []struct {
		name, trusted, remote, client, wantRemote string
		wantTLS                                  bool
	}{
		{"trusted", "172.29.50.2", "172.29.50.2:1234", "203.0.113.5", "203.0.113.5:0", true},
		{"spoofed", "172.29.50.2", "203.0.113.6:1234", "203.0.113.5", "203.0.113.6:1234", false},
		{"disabled", "", "172.29.50.2:1234", "203.0.113.5", "172.29.50.2:1234", false},
		{"invalid client", "172.29.50.2", "172.29.50.2:1234", "203.0.113.5, 203.0.113.6", "172.29.50.2:1234", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", "http://dianjie.org/", nil)
			r.RemoteAddr = tc.remote
			r.Header.Set("X-Forwarded-Proto", "https")
			r.Header.Set("X-Real-IP", tc.client)
			TrustedProxy(http.HandlerFunc(func(w http.ResponseWriter, got *http.Request) {
				if (got.TLS != nil) != tc.wantTLS || got.RemoteAddr != tc.wantRemote {
					t.Fatalf("TLS=%v remote=%s", got.TLS != nil, got.RemoteAddr)
				}
			}), tc.trusted).ServeHTTP(httptest.NewRecorder(), r)
			if r.TLS != nil || r.RemoteAddr != tc.remote {
				t.Fatal("middleware mutated original request")
			}
		})
	}
}
