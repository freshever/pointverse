ALTER TABLE user_identities DROP CONSTRAINT user_identities_provider_check;
ALTER TABLE user_identities ADD CONSTRAINT user_identities_provider_check CHECK (provider IN ('google', 'apple', 'email'));

CREATE TABLE email_credentials (
    email TEXT PRIMARY KEY CHECK (email = lower(email)),
    user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
