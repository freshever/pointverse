package httpapi

import (
	"crypto/tls"
	"net"
	"net/http"
)

// TrustedProxy accepts forwarding metadata only from the explicitly configured
// proxy. That proxy must overwrite both headers rather than append client input.
func TrustedProxy(next http.Handler, trustedIP string) http.Handler {
	trusted := net.ParseIP(trustedIP)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err == nil && trusted != nil && trusted.Equal(net.ParseIP(host)) {
			r = r.Clone(r.Context())
			if r.Header.Get("X-Forwarded-Proto") == "https" {
				r.TLS = &tls.ConnectionState{}
			}
			if client := net.ParseIP(r.Header.Get("X-Real-IP")); client != nil {
				r.RemoteAddr = net.JoinHostPort(client.String(), "0")
			}
		}
		next.ServeHTTP(w, r)
	})
}
