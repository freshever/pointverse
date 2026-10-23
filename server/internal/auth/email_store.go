package auth

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

func (s *Store) RegisterEmail(ctx context.Context, email, passwordHash string) (Session, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Session{}, err
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", "email:"+email); err != nil {
		return Session{}, err
	}
	var exists bool
	if err = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM email_credentials WHERE email=$1)", email).Scan(&exists); err != nil {
		return Session{}, err
	}
	if exists {
		return Session{}, ErrEmailExists
	}
	var id string
	if err = tx.QueryRow(ctx, "INSERT INTO users DEFAULT VALUES RETURNING id::text").Scan(&id); err != nil {
		return Session{}, err
	}
	if _, err = tx.Exec(ctx, "INSERT INTO email_credentials(email,user_id,password_hash) VALUES($1,$2,$3)", email, id, passwordHash); err != nil {
		return Session{}, err
	}
	if _, err = tx.Exec(ctx, "INSERT INTO user_identities(provider,subject,user_id,email,email_verified) VALUES('email',$1,$2,$1,false)", email, id); err != nil {
		return Session{}, err
	}
	result, err := issueSession(ctx, tx, id)
	if err != nil {
		return Session{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return Session{}, err
	}
	return result, nil
}
func (s *Store) LoginEmail(ctx context.Context, email, password string) (Session, error) {
	var id, hash string
	err := s.pool.QueryRow(ctx, "SELECT user_id::text,password_hash FROM email_credentials WHERE email=$1", email).Scan(&id, &hash)
	if errors.Is(err, pgx.ErrNoRows) {
		verifyPassword(password, dummyPasswordHash())
		return Session{}, ErrCredentials
	}
	if err != nil {
		return Session{}, err
	}
	if !verifyPassword(password, hash) {
		return Session{}, ErrCredentials
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Session{}, err
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(ctx, "UPDATE user_identities SET last_login_at=now() WHERE provider='email' AND user_id=$1", id); err != nil {
		return Session{}, err
	}
	result, err := issueSession(ctx, tx, id)
	if err != nil {
		return Session{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return Session{}, err
	}
	return result, nil
}
func issueSession(ctx context.Context, tx pgx.Tx, id string) (Session, error) {
	result := Session{AccessToken: secret(), TokenType: "Bearer", ExpiresAt: time.Now().UTC().Add(SessionLifetime)}
	if _, err := tx.Exec(ctx, "INSERT INTO auth_sessions(token_hash,user_id,expires_at) VALUES($1,$2,$3)", digest(result.AccessToken), id, result.ExpiresAt); err != nil {
		return Session{}, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM auth_sessions WHERE token_hash IN (SELECT token_hash FROM auth_sessions WHERE expires_at<=now() LIMIT 100)`); err != nil {
		return Session{}, err
	}
	user, err := loadUser(ctx, tx, id)
	result.User = user
	return result, err
}
