package auth

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

var (
	ErrInvalidToken     = errors.New("invalid identity token")
	ErrProviderDisabled = errors.New("provider disabled")
	ErrUnauthorized     = errors.New("unauthorized")
)

type Identity struct {
	Provider, Subject, Email, Name, Nonce string
	EmailVerified                         bool
	ExpiresAt                             time.Time
	TokenHash                             [32]byte
}

type TokenVerifier interface {
	Enabled(string) bool
	Verify(context.Context, string, string) (Identity, error)
}

type provider struct {
	verifier  *oidc.IDTokenVerifier
	audiences []string
}

type Providers struct{ providers map[string]provider }

func NewProviders(ctx context.Context, googleIDs, appleIDs []string) *Providers {
	ctx = oidc.ClientContext(ctx, &http.Client{Timeout: 5 * time.Second})
	p := &Providers{providers: make(map[string]provider)}
	for _, item := range []struct {
		name, issuer, keys string
		ids                []string
	}{
		{"google", "https://accounts.google.com", "https://www.googleapis.com/oauth2/v3/certs", googleIDs},
		{"apple", "https://appleid.apple.com", "https://appleid.apple.com/auth/keys", appleIDs},
	} {
		if len(item.ids) == 0 {
			continue
		}
		// Audience allowlist is checked below to support multiple native/web client IDs.
		verifier := oidc.NewVerifier(item.issuer, oidc.NewRemoteKeySet(ctx, item.keys), &oidc.Config{
			SkipClientIDCheck: true, SupportedSigningAlgs: []string{oidc.RS256},
		})
		p.providers[item.name] = provider{verifier: verifier, audiences: slices.Clone(item.ids)}
	}
	return p
}

func (p *Providers) Enabled(name string) bool { _, ok := p.providers[name]; return ok }

func (p *Providers) Verify(ctx context.Context, name, raw string) (Identity, error) {
	spec, ok := p.providers[name]
	if !ok {
		return Identity{}, ErrProviderDisabled
	}
	if len(raw) == 0 || len(raw) > 16384 {
		return Identity{}, ErrInvalidToken
	}
	token, err := spec.verifier.Verify(ctx, raw)
	if err != nil {
		return Identity{}, ErrInvalidToken
	}
	audienceOK := false
	for _, aud := range token.Audience {
		if slices.Contains(spec.audiences, aud) {
			audienceOK = true
		}
	}
	if !audienceOK || token.Subject == "" || len(token.Subject) > 255 || token.IssuedAt.IsZero() || token.IssuedAt.After(time.Now().Add(time.Minute)) || !token.Expiry.After(token.IssuedAt) {
		return Identity{}, ErrInvalidToken
	}
	var claims struct {
		Email           string    `json:"email"`
		EmailVerified   boolClaim `json:"email_verified"`
		Name            string    `json:"name"`
		AuthorizedParty string    `json:"azp"`
	}
	if err := token.Claims(&claims); err != nil {
		return Identity{}, ErrInvalidToken
	}
	if (len(token.Audience) > 1 && claims.AuthorizedParty == "") || (claims.AuthorizedParty != "" && !slices.Contains(spec.audiences, claims.AuthorizedParty)) {
		return Identity{}, ErrInvalidToken
	}
	if len(claims.Email) > 320 || len(claims.Name) > 256 {
		return Identity{}, ErrInvalidToken
	}
	if name == "apple" && token.Nonce == "" {
		return Identity{}, ErrInvalidToken
	}
	// Canonicalize base64 segments so equivalent signature encodings cannot bypass replay detection.
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return Identity{}, ErrInvalidToken
	}
	for i, part := range parts {
		decoded, err := base64.RawURLEncoding.DecodeString(part)
		if err != nil {
			return Identity{}, ErrInvalidToken
		}
		parts[i] = base64.RawURLEncoding.EncodeToString(decoded)
	}
	return Identity{Provider: name, Subject: token.Subject, Email: claims.Email, EmailVerified: bool(claims.EmailVerified), Name: claims.Name, Nonce: token.Nonce, ExpiresAt: token.Expiry, TokenHash: sha256.Sum256([]byte(strings.Join(parts, ".")))}, nil
}

// Apple may encode email_verified as a string while Google uses a JSON boolean.
type boolClaim bool

func (b *boolClaim) UnmarshalJSON(data []byte) error {
	switch string(data) {
	case "true", `"true"`:
		*b = true
	case "false", `"false"`, "null":
		*b = false
	default:
		return errors.New("invalid email_verified claim")
	}
	return nil
}
