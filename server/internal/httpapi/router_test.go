package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthAndReadiness(t *testing.T) {
	for _, tc := range []struct {
		name, path, status string
		check              ReadinessCheck
		code               int
	}{
		{"health independent of database", "/healthz", "ok", nil, 200},
		{"ready", "/readyz", "ready", func(context.Context) error { return nil }, 200},
		{"database unavailable", "/readyz", "not_ready", func(context.Context) error { return errors.New("private connection details") }, 503},
		{"missing check", "/readyz", "not_ready", nil, 503},
		{"unknown route", "/unknown", "not_found", nil, 404},
	} {
		t.Run(tc.name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			New(tc.check, nil).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, tc.path, nil))
			if recorder.Code != tc.code {
				t.Fatalf("code = %d, want %d", recorder.Code, tc.code)
			}
			var body map[string]string
			if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if body["status"] != tc.status || len(body) != 1 {
				t.Fatalf("unexpected body: %v", body)
			}
		})
	}
}
