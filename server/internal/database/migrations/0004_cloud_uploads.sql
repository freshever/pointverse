CREATE TABLE cloud_assets (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sha256 TEXT NOT NULL CHECK (sha256 ~ '^[a-f0-9]{64}$'),
    byte_count BIGINT NOT NULL CHECK (byte_count > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, sha256)
);
CREATE TABLE cloud_point_versions (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    point_id UUID NOT NULL,
    manifest_hash TEXT NOT NULL CHECK (manifest_hash ~ '^[a-f0-9]{64}$'),
    revision BIGINT NOT NULL CHECK (revision > 0),
    title TEXT NOT NULL,
    preview TEXT NOT NULL,
    created_at DOUBLE PRECISION NOT NULL,
    manifest BYTEA NOT NULL,
    asset_count INTEGER NOT NULL,
    uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, point_id, manifest_hash)
);
CREATE INDEX cloud_point_versions_feed ON cloud_point_versions(user_id, uploaded_at DESC, manifest_hash DESC, point_id DESC);
