package auth

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"net/url"
	"time"
)

const webCookie = "pointverse_session"

func (h *Handler) registerEmailRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/auth/email/register", h.limited(h.emailAuth(true, false)))
	mux.HandleFunc("POST /v1/auth/email/login", h.limited(h.emailAuth(false, false)))
	mux.HandleFunc("POST /web/auth/register", h.sameOrigin(h.limited(h.emailAuth(true, true))))
	mux.HandleFunc("POST /web/auth/login", h.sameOrigin(h.limited(h.emailAuth(false, true))))
	mux.HandleFunc("GET /web/auth/me", h.webMe)
	mux.HandleFunc("POST /web/auth/logout", h.sameOrigin(h.webLogout))
}
func (h *Handler) sameOrigin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		origin, err := url.Parse(r.Header.Get("Origin"))
		scheme := "http"
		if r.TLS != nil {
			scheme = "https"
		}
		if err != nil || origin.Scheme != scheme || origin.Host != r.Host || origin.User != nil || origin.Path != "" || origin.RawQuery != "" || origin.Fragment != "" {
			fail(w, 403, "invalid_origin")
			return
		}
		next(w, r)
	}
}
func (h *Handler) emailAuth(register, browser bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil || media != "application/json" {
			fail(w, 415, "json_required")
			return
		}
		var input struct {
			Email        string `json:"email"`
			Password     string `json:"password"`
			Confirmation string `json:"password_confirmation,omitempty"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&input); err != nil {
			fail(w, 400, "invalid_request")
			return
		}
		if err := decoder.Decode(new(any)); err != io.EOF {
			fail(w, 400, "invalid_request")
			return
		}
		email, valid := normalizeEmail(input.Email)
		if !valid {
			fail(w, 400, "invalid_email")
			return
		}
		if len(input.Password) > 512 || input.Password == "" {
			fail(w, 400, "invalid_password")
			return
		}
		if register && !validPassword(input.Password) {
			fail(w, 400, "invalid_password")
			return
		}
		if register && input.Password != input.Confirmation {
			fail(w, 400, "password_mismatch")
			return
		}
		select {
		case h.passwordSlots <- struct{}{}:
			defer func() { <-h.passwordSlots }()
		default:
			w.Header().Set("Retry-After", "2")
			fail(w, 503, "auth_busy")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		var result Session
		if register {
			result, err = h.store.RegisterEmail(ctx, email, hashPassword(input.Password))
		} else {
			result, err = h.store.LoginEmail(ctx, email, input.Password)
		}
		if errors.Is(err, ErrEmailExists) {
			fail(w, 409, "email_exists")
			return
		}
		if errors.Is(err, ErrCredentials) {
			fail(w, 401, "invalid_credentials")
			return
		}
		if err != nil {
			serverError(w, err)
			return
		}
		status := http.StatusOK
		if register {
			status = http.StatusCreated
		}
		if browser {
			h.setCookie(w, r, result.AccessToken, result.ExpiresAt)
			reply(w, status, map[string]any{"user": result.User, "expires_at": result.ExpiresAt})
		} else {
			reply(w, status, result)
		}
	}
}
func cookieToken(r *http.Request) string {
	cookie, err := r.Cookie(webCookie)
	if err != nil {
		return ""
	}
	return cookie.Value
}
func (h *Handler) setCookie(w http.ResponseWriter, r *http.Request, token string, expiry time.Time) {
	cookie := &http.Cookie{Name: webCookie, Value: token, Path: "/web/", HttpOnly: true, SameSite: http.SameSiteStrictMode, Secure: r.TLS != nil, Expires: expiry, MaxAge: int(time.Until(expiry).Seconds())}
	if token == "" {
		cookie.MaxAge = -1
	}
	http.SetCookie(w, cookie)
}
func (h *Handler) webMe(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	user, err := h.store.CurrentUser(ctx, cookieToken(r))
	if errors.Is(err, ErrUnauthorized) {
		h.setCookie(w, r, "", time.Unix(1, 0))
		fail(w, 401, "unauthorized")
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	reply(w, 200, map[string]any{"user": user})
}
func (h *Handler) webLogout(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	token := cookieToken(r)
	if token != "" {
		if err := h.store.Logout(ctx, token); err != nil && !errors.Is(err, ErrUnauthorized) {
			serverError(w, err)
			return
		}
	}
	h.setCookie(w, r, "", time.Unix(1, 0))
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(204)
}
