package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

const SessionLifetime = 7 * 24 * time.Hour

type User struct {
	ID          string            `json:"id"`
	DisplayName string            `json:"display_name"`
	CreatedAt   time.Time         `json:"created_at"`
	Identities  []AccountIdentity `json:"identities"`
}
type AccountIdentity struct {
	Provider      string `json:"provider"`
	Email         string `json:"email,omitempty"`
	EmailVerified bool   `json:"email_verified"`
}
type Session struct {
	AccessToken string    `json:"access_token"`
	TokenType   string    `json:"token_type"`
	ExpiresAt   time.Time `json:"expires_at"`
	User        User      `json:"user"`
}
type Challenge struct {
	ID        string    `json:"challenge_id"`
	Nonce     string    `json:"nonce"`
	ExpiresAt time.Time `json:"expires_at"`
}

type Store struct{ pool *pgxpool.Pool }

func NewStore(pool *pgxpool.Pool) *Store { return &Store{pool: pool} }

func secret() string {
	data := make([]byte, 32)
	// Go 1.25 crypto/rand.Read always fills the buffer or terminates the process.
	_, _ = rand.Read(data)
	return base64.RawURLEncoding.EncodeToString(data)
}
func digest(value string) []byte { sum := sha256.Sum256([]byte(value)); return sum[:] }

func (s *Store) CreateChallenge(ctx context.Context) (Challenge, error) {
	c := Challenge{ID: secret(), Nonce: secret(), ExpiresAt: time.Now().UTC().Add(10 * time.Minute)}
	_, err := s.pool.Exec(ctx, `DELETE FROM apple_login_challenges WHERE id_hash IN (SELECT id_hash FROM apple_login_challenges WHERE expires_at<=now() LIMIT 100)`)
	if err != nil {
		return Challenge{}, err
	}
	_, err = s.pool.Exec(ctx, "INSERT INTO apple_login_challenges(id_hash,nonce_hash,expires_at) VALUES($1,$2,$3)", digest(c.ID), digest(c.Nonce), c.ExpiresAt)
	return c, err
}

func (s *Store) Login(ctx context.Context, identity Identity, challengeID string) (Session, error) {
	session := Session{AccessToken: secret(), TokenType: "Bearer", ExpiresAt: time.Now().UTC().Add(SessionLifetime)}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Session{}, err
	}
	defer tx.Rollback(context.Background())
	// Serialize first logins for one external identity without serializing all users.
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", identity.Provider+":"+identity.Subject); err != nil {
		return Session{}, err
	}
	if identity.Provider == "apple" {
		result, err := tx.Exec(ctx, "DELETE FROM apple_login_challenges WHERE id_hash=$1 AND nonce_hash=$2 AND expires_at>now()", digest(challengeID), digest(identity.Nonce))
		if err != nil {
			return Session{}, err
		}
		if result.RowsAffected() != 1 {
			return Session{}, ErrInvalidToken
		}
	}
	// Retain token fingerprints until provider expiry; a credential can create only one session.
	if _, err = tx.Exec(ctx, `DELETE FROM used_identity_tokens WHERE token_hash IN (SELECT token_hash FROM used_identity_tokens WHERE expires_at<=now() LIMIT 100)`); err != nil {
		return Session{}, err
	}
	_, err = tx.Exec(ctx, "INSERT INTO used_identity_tokens(token_hash,expires_at) VALUES($1,$2)", identity.TokenHash[:], identity.ExpiresAt)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return Session{}, ErrInvalidToken
		}
		return Session{}, err
	}
	err = tx.QueryRow(ctx, "SELECT user_id::text FROM user_identities WHERE provider=$1 AND subject=$2", identity.Provider, identity.Subject).Scan(&session.User.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		err = tx.QueryRow(ctx, "INSERT INTO users(display_name) VALUES($1) RETURNING id::text", identity.Name).Scan(&session.User.ID)
		if err != nil {
			return Session{}, err
		}
		_, err = tx.Exec(ctx, "INSERT INTO user_identities(provider,subject,user_id,email,email_verified) VALUES($1,$2,$3,$4,$5)", identity.Provider, identity.Subject, session.User.ID, identity.Email, identity.EmailVerified)
	} else if err == nil {
		_, err = tx.Exec(ctx, `UPDATE user_identities SET email=CASE WHEN $3='' THEN email ELSE $3 END, email_verified=CASE WHEN $3='' THEN email_verified ELSE $4 END, last_login_at=now() WHERE provider=$1 AND subject=$2`, identity.Provider, identity.Subject, identity.Email, identity.EmailVerified)
	}
	if err != nil {
		return Session{}, err
	}
	if _, err = tx.Exec(ctx, "INSERT INTO auth_sessions(token_hash,user_id,expires_at) VALUES($1,$2,$3)", digest(session.AccessToken), session.User.ID, session.ExpiresAt); err != nil {
		return Session{}, err
	}
	if _, err = tx.Exec(ctx, `DELETE FROM auth_sessions WHERE token_hash IN (SELECT token_hash FROM auth_sessions WHERE expires_at<=now() LIMIT 100)`); err != nil {
		return Session{}, err
	}
	session.User, err = loadUser(ctx, tx, session.User.ID)
	if err != nil {
		return Session{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return Session{}, err
	}
	return session, nil
}

type queryer interface {
	QueryRow(context.Context, string, ...any) pgx.Row
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

func loadUser(ctx context.Context, q queryer, id string) (User, error) {
	u := User{Identities: []AccountIdentity{}}
	if err := q.QueryRow(ctx, "SELECT id::text,display_name,created_at FROM users WHERE id=$1", id).Scan(&u.ID, &u.DisplayName, &u.CreatedAt); err != nil {
		return User{}, err
	}
	rows, err := q.Query(ctx, "SELECT provider,email,email_verified FROM user_identities WHERE user_id=$1 ORDER BY provider", id)
	if err != nil {
		return User{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var i AccountIdentity
		if err := rows.Scan(&i.Provider, &i.Email, &i.EmailVerified); err != nil {
			return User{}, err
		}
		u.Identities = append(u.Identities, i)
	}
	return u, rows.Err()
}

func validSecret(token string) bool {
	data, err := base64.RawURLEncoding.Strict().DecodeString(token)
	return err == nil && len(data) == 32 && len(token) == 43
}
func (s *Store) CurrentUser(ctx context.Context, token string) (User, error) {
	if !validSecret(token) {
		return User{}, ErrUnauthorized
	}
	var id string
	err := s.pool.QueryRow(ctx, "SELECT user_id::text FROM auth_sessions WHERE token_hash=$1 AND expires_at>now()", digest(token)).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return User{}, ErrUnauthorized
	}
	if err != nil {
		return User{}, err
	}
	return loadUser(ctx, s.pool, id)
}
func (s *Store) Logout(ctx context.Context, token string) error {
	if !validSecret(token) {
		return ErrUnauthorized
	}
	// Idempotent: already revoked and expired tokens may also be discarded by the client.
	_, err := s.pool.Exec(ctx, "DELETE FROM auth_sessions WHERE token_hash=$1", digest(token))
	return err
}
