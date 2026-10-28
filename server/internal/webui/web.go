package webui

import (
	"embed"
	"io/fs"
	"net/http"
)

//go:embed assets/*
var assets embed.FS

func Register(mux *http.ServeMux) {
	files, _ := fs.Sub(assets, "assets")
	handler := http.StripPrefix("/account/", http.FileServer(http.FS(files)))
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/account/", http.StatusFound) })
	mux.Handle("GET /account/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "no-store")
		switch r.URL.Path {
		case "/account/app-icon-v1.png", "/account/favicon-v1.png", "/account/apple-touch-icon-v1.png":
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		}
		handler.ServeHTTP(w, r)
	}))
}
