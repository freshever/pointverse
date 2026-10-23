package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/go-jose/go-jose/v4"
)

type fixture struct {
	providers *Providers
	key       *rsa.PrivateKey
}

func newFixture(t *testing.T) fixture {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	jwks := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: &key.PublicKey, KeyID: "test-key", Algorithm: "RS256", Use: "sig"}}})
	}))
	t.Cleanup(jwks.Close)
	p := &Providers{providers: map[string]provider{}}
	for _, name := range []string{"google", "apple"} {
		issuer := "https://accounts.google.com"
		if name == "apple" {
			issuer = "https://appleid.apple.com"
		}
		p.providers[name] = provider{audiences: []string{"test-client"}, verifier: oidc.NewVerifier(issuer, oidc.NewRemoteKeySet(context.Background(), jwks.URL), &oidc.Config{SkipClientIDCheck: true, SupportedSigningAlgs: []string{oidc.RS256}})}
	}
	return fixture{p, key}
}
func (f fixture) token(t *testing.T, provider, subject, nonce string, change func(map[string]any)) string {
	t.Helper()
	issuer := "https://accounts.google.com"
	if provider == "apple" {
		issuer = "https://appleid.apple.com"
	}
	claims := map[string]any{"iss": issuer, "aud": "test-client", "sub": subject, "iat": time.Now().Add(-time.Second).Unix(), "exp": time.Now().Add(time.Hour).Unix(), "email": "same@example.com", "email_verified": true, "nonce": nonce}
	if change != nil {
		change(claims)
	}
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: f.key}, (&jose.SignerOptions{}).WithHeader("kid", "test-key"))
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(claims)
	signed, err := signer.Sign(data)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := signed.CompactSerialize()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
func TestProviderVerification(t *testing.T) {
	f := newFixture(t)
	for _, tc := range []struct {
		name   string
		modify func(map[string]any)
		valid  bool
	}{
		{"valid", nil, true},
		{"google alternate issuer", func(c map[string]any) { c["iss"] = "accounts.google.com" }, true},
		{"wrong issuer", func(c map[string]any) { c["iss"] = "https://evil.example" }, false},
		{"wrong audience", func(c map[string]any) { c["aud"] = "another-app" }, false},
		{"expired", func(c map[string]any) { c["exp"] = time.Now().Add(-time.Hour).Unix() }, false},
		{"future issued", func(c map[string]any) { c["iat"] = time.Now().Add(time.Hour).Unix() }, false},
		{"missing issued", func(c map[string]any) { delete(c, "iat") }, false},
		{"empty subject", func(c map[string]any) { c["sub"] = "" }, false},
		{"wrong authorized party", func(c map[string]any) { c["azp"] = "another-app" }, false},
		{"multiple audiences without azp", func(c map[string]any) { c["aud"] = []string{"test-client", "other"} }, false},
		{"verified as string", func(c map[string]any) { c["email_verified"] = "true" }, true},
		{"invalid verified", func(c map[string]any) { c["email_verified"] = 5 }, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := f.providers.Verify(context.Background(), "google", f.token(t, "google", "google-user", "", tc.modify))
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%v err=%v", tc.valid, err)
			}
		})
	}
	good := f.token(t, "apple", "apple-user", "nonce", nil)
	if _, err := f.providers.Verify(context.Background(), "apple", good); err != nil {
		t.Fatal(err)
	}
	if _, err := f.providers.Verify(context.Background(), "google", good); err == nil {
		t.Fatal("cross-provider token accepted")
	}
	if _, err := f.providers.Verify(context.Background(), "apple", f.token(t, "apple", "u", "", nil)); err == nil {
		t.Fatal("missing nonce accepted")
	}
	if _, err := f.providers.Verify(context.Background(), "google", "eyJhbGciOiJub25lIn0.e30."); err == nil {
		t.Fatal("unsigned token accepted")
	}
	other := newFixture(t)
	if _, err := f.providers.Verify(context.Background(), "google", other.token(t, "google", "u", "", nil)); err == nil {
		t.Fatal("forged signature accepted")
	}
	disabled := NewProviders(context.Background(), nil, nil)
	if disabled.Enabled("google") {
		t.Fatal("unconfigured provider enabled")
	}
	if _, err := disabled.Verify(context.Background(), "google", good); err != ErrProviderDisabled {
		t.Fatalf("disabled provider: %v", err)
	}
}
