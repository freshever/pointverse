-- Business tables will be introduced with their corresponding feature contracts.
CREATE TABLE service_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO service_metadata (key, value) VALUES ('service', 'pointverse');
