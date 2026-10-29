CREATE TABLE musefinger_scores (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    id UUID NOT NULL,
    title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
    composer TEXT NOT NULL CHECK (length(composer) <= 300),
    source TEXT NOT NULL CHECK (source IN ('import','scan','generated','library')),
    musicxml TEXT NOT NULL CHECK (octet_length(musicxml) BETWEEN 1 AND 4194304),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, id)
);
CREATE INDEX musefinger_scores_updated ON musefinger_scores(user_id, updated_at DESC, id);
