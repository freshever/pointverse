package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"net/mail"
	"strings"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"
)

var (
	ErrEmailExists = errors.New("email already registered")
	ErrCredentials = errors.New("invalid email or password")
)

const passwordPrefix = "$argon2id$v=19$m=32768,t=3,p=2$"

func normalizeEmail(raw string) (string, bool) {
	email := strings.ToLower(strings.TrimSpace(raw))
	if len(email) > 254 || strings.ContainsAny(email, "\r\n") {
		return "", false
	}
	address, err := mail.ParseAddress(email)
	// Display names and quoted/ambiguous addresses are not account identifiers.
	if err != nil || address.Address != email || !strings.Contains(email, "@") || strings.ContainsAny(email, " <>\"\t") {
		return "", false
	}
	return email, true
}
func validPassword(password string) bool {
	length := utf8.RuneCountInString(password)
	return utf8.ValidString(password) && length >= 12 && length <= 128 && len(password) <= 512
}
func hashPassword(password string) string {
	salt := make([]byte, 16)
	_, _ = rand.Read(salt)
	key := argon2.IDKey([]byte(password), salt, 3, 32*1024, 2, 32)
	return passwordPrefix + base64.RawStdEncoding.EncodeToString(salt) + "$" + base64.RawStdEncoding.EncodeToString(key)
}
func verifyPassword(password, encoded string) bool {
	parts := strings.Split(strings.TrimPrefix(encoded, passwordPrefix), "$")
	if !strings.HasPrefix(encoded, passwordPrefix) || len(parts) != 2 {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[0])
	if err != nil || len(salt) != 16 {
		return false
	}
	expected, err := base64.RawStdEncoding.DecodeString(parts[1])
	if err != nil || len(expected) != 32 {
		return false
	}
	actual := argon2.IDKey([]byte(password), salt, 3, 32*1024, 2, 32)
	return subtle.ConstantTimeCompare(actual, expected) == 1
}

// Unknown accounts perform the same password derivation as known accounts.
func dummyPasswordHash() string {
	return passwordPrefix + base64.RawStdEncoding.EncodeToString(make([]byte, 16)) + "$" + base64.RawStdEncoding.EncodeToString(make([]byte, 32))
}
