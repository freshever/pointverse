package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"pointverse/server/internal/auth"
	"pointverse/server/internal/webui"
	"time"
)

type ReadinessCheck func(context.Context) error
type Registrar interface{ Register(*http.ServeMux) }

func New(check ReadinessCheck, authentication *auth.Handler, services ...Registrar) http.Handler {
	mux := http.NewServeMux()
	webui.Register(mux)
	for _, service := range services {
		if service != nil {
			service.Register(mux)
		}
	}
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		respond(w, http.StatusOK, "ok")
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if check == nil || check(ctx) != nil {
			respond(w, http.StatusServiceUnavailable, "not_ready")
			return
		}
		respond(w, http.StatusOK, "ready")
	})
	if authentication != nil {
		authentication.Register(mux)
	}
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { respond(w, http.StatusNotFound, "not_found") })
	return mux
}

func respond(w http.ResponseWriter, code int, status string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": status})
}
