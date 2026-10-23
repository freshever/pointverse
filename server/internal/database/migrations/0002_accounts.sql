CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    display_name TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Provider subject, never email, is the external account identity.
CREATE TABLE user_identities (
    provider TEXT NOT NULL CHECK (provider IN ('google', 'apple')),
    subject TEXT NOT NULL,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    email TEXT NOT NULL DEFAULT '',
    email_verified BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, subject),
    UNIQUE (user_id, provider)
);

CREATE TABLE auth_sessions (
    token_hash BYTEA PRIMARY KEY CHECK (octet_length(token_hash) = 32),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX auth_sessions_user_id_idx ON auth_sessions(user_id);
CREATE INDEX auth_sessions_expiry_idx ON auth_sessions(expires_at);

CREATE TABLE apple_login_challenges (
    id_hash BYTEA PRIMARY KEY CHECK (octet_length(id_hash) = 32),
    nonce_hash BYTEA NOT NULL CHECK (octet_length(nonce_hash) = 32),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX apple_login_challenges_expiry_idx ON apple_login_challenges(expires_at);

CREATE TABLE used_identity_tokens (
    token_hash BYTEA PRIMARY KEY CHECK (octet_length(token_hash) = 32),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX used_identity_tokens_expiry_idx ON used_identity_tokens(expires_at);
