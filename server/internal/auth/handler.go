package auth

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

type Handler struct {
	store         *Store
	verifier      TokenVerifier
	limiter       *limiter
	passwordSlots chan struct{}
}

func NewHandler(store *Store, verifier TokenVerifier) *Handler {
	return &Handler{store: store, verifier: verifier, limiter: &limiter{entries: make(map[string]bucket)}, passwordSlots: make(chan struct{}, 2)}
}
func (h *Handler) Register(mux *http.ServeMux) {
	h.registerEmailRoutes(mux)
	mux.HandleFunc("GET /v1/auth/providers", func(w http.ResponseWriter, r *http.Request) {
		reply(w, 200, map[string]bool{"google": h.verifier.Enabled("google"), "apple": h.verifier.Enabled("apple")})
	})
	mux.HandleFunc("POST /v1/auth/apple/challenge", h.limited(h.challenge))
	mux.HandleFunc("POST /v1/auth/google", h.limited(h.login("google")))
	mux.HandleFunc("POST /v1/auth/apple", h.limited(h.login("apple")))
	mux.HandleFunc("GET /v1/auth/me", h.me)
	mux.HandleFunc("POST /v1/auth/logout", h.logout)
}
func (h *Handler) limited(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			host = r.RemoteAddr
		}
		// Do not trust X-Forwarded-For from an arbitrary client.
		if !h.limiter.allow(host, time.Now()) {
			w.Header().Set("Retry-After", "60")
			fail(w, 429, "rate_limited")
			return
		}
		next(w, r)
	}
}
func (h *Handler) challenge(w http.ResponseWriter, r *http.Request) {
	if !h.verifier.Enabled("apple") {
		fail(w, 503, "provider_disabled")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	c, err := h.store.CreateChallenge(ctx)
	if err != nil {
		serverError(w, err)
		return
	}
	reply(w, 201, c)
}
func (h *Handler) login(provider string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !h.verifier.Enabled(provider) {
			fail(w, 503, "provider_disabled")
			return
		}
		media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil || media != "application/json" {
			fail(w, 415, "json_required")
			return
		}
		var input struct {
			IDToken     string `json:"id_token"`
			ChallengeID string `json:"challenge_id,omitempty"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, 20<<10)
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&input); err != nil {
			fail(w, 400, "invalid_request")
			return
		}
		if err := decoder.Decode(new(any)); err != io.EOF || input.IDToken == "" || len(input.IDToken) > 16384 {
			fail(w, 400, "invalid_request")
			return
		}
		if (provider == "apple" && !validSecret(input.ChallengeID)) || (provider == "google" && input.ChallengeID != "") {
			fail(w, 400, "invalid_request")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		identity, err := h.verifier.Verify(ctx, provider, input.IDToken)
		if err != nil {
			fail(w, 401, "invalid_identity_token")
			return
		}
		session, err := h.store.Login(ctx, identity, input.ChallengeID)
		if errors.Is(err, ErrInvalidToken) {
			fail(w, 401, "invalid_identity_token")
			return
		}
		if err != nil {
			serverError(w, err)
			return
		}
		reply(w, 200, session)
	}
}
func bearer(r *http.Request) string {
	fields := strings.Fields(r.Header.Get("Authorization"))
	if len(fields) != 2 || !strings.EqualFold(fields[0], "Bearer") {
		return ""
	}
	return fields[1]
}
func (h *Handler) me(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	user, err := h.store.CurrentUser(ctx, bearer(r))
	if errors.Is(err, ErrUnauthorized) {
		w.Header().Set("WWW-Authenticate", "Bearer")
		fail(w, 401, "unauthorized")
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	reply(w, 200, user)
}
func (h *Handler) logout(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	err := h.store.Logout(ctx, bearer(r))
	if errors.Is(err, ErrUnauthorized) {
		fail(w, 401, "unauthorized")
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}
func reply(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}
func fail(w http.ResponseWriter, code int, value string) {
	reply(w, code, map[string]any{"error": map[string]string{"code": value}})
}
func serverError(w http.ResponseWriter, err error) {
	// Do not log tokens, request bodies, or SQL errors that may contain identity data.
	slog.Error("authentication storage operation failed", "error_type", errorType(err))
	fail(w, 500, "internal_error")
}
func errorType(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	return "database"
}

type bucket struct {
	start time.Time
	count int
}
type limiter struct {
	mu      sync.Mutex
	entries map[string]bucket
}

func (l *limiter) allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.entries[key]
	if !ok && len(l.entries) >= 4096 {
		for k, v := range l.entries {
			if now.Sub(v.start) >= time.Minute {
				delete(l.entries, k)
			}
		}
		if len(l.entries) >= 4096 {
			return false
		}
	}
	if !ok || now.Sub(b.start) >= time.Minute {
		b = bucket{start: now}
	}
	if b.count >= 20 {
		return false
	}
	b.count++
	l.entries[key] = b
	return true
}

// RequireUser authenticates native API requests without accepting browser cookies.
func (h *Handler) RequireUser(next func(http.ResponseWriter, *http.Request, User)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		user, err := h.store.CurrentUser(ctx, bearer(r))
		cancel()
		if errors.Is(err, ErrUnauthorized) {
			fail(w, 401, "unauthorized")
			return
		}
		if err != nil {
			serverError(w, err)
			return
		}
		next(w, r, user)
	}
}

// RequireWebUser accepts only the browser cookie scoped to /web/.
func (h *Handler) RequireWebUser(next func(http.ResponseWriter, *http.Request, User)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		user, err := h.store.CurrentUser(ctx, cookieToken(r))
		cancel()
		if errors.Is(err, ErrUnauthorized) {
			fail(w, 401, "unauthorized")
			return
		}
		if err != nil {
			serverError(w, err)
			return
		}
		next(w, r, user)
	}
}
