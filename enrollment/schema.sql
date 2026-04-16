PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schools (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    slug            TEXT NOT NULL UNIQUE,
    display_name    TEXT NOT NULL,
    contact_email   TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS enroll_tokens (
    token_hash      TEXT PRIMARY KEY,
    school_id       INTEGER NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
    issued_at       TEXT NOT NULL DEFAULT (datetime('now')),
    expires_at      TEXT NOT NULL,
    consumed_at     TEXT
);

CREATE TABLE IF NOT EXISTS peers (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    school_id       INTEGER NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
    hostname        TEXT NOT NULL UNIQUE,
    serial          TEXT NOT NULL UNIQUE,
    pubkey          TEXT NOT NULL UNIQUE,
    tunnel_ip       TEXT NOT NULL UNIQUE,
    virtual_subnet  TEXT NOT NULL UNIQUE,
    real_subnets    TEXT NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('pending','active','revoked')),
    enrolled_at     TEXT NOT NULL DEFAULT (datetime('now')),
    approved_at     TEXT,
    revoked_at      TEXT,
    last_handshake  TEXT
);

CREATE INDEX IF NOT EXISTS idx_peers_status ON peers(status);
CREATE INDEX IF NOT EXISTS idx_peers_school ON peers(school_id);
