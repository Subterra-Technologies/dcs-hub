PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS districts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    slug            TEXT NOT NULL UNIQUE,
    display_name    TEXT NOT NULL,
    contact_email   TEXT,
    tunnel_subnet   TEXT NOT NULL UNIQUE,
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS enroll_tokens (
    token_hash      TEXT PRIMARY KEY,
    district_id     INTEGER NOT NULL REFERENCES districts(id) ON DELETE CASCADE,
    issued_at       TEXT NOT NULL DEFAULT (datetime('now')),
    expires_at      TEXT NOT NULL,
    consumed_at     TEXT
);

CREATE TABLE IF NOT EXISTS zabbix_vms (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    district_id     INTEGER NOT NULL REFERENCES districts(id) ON DELETE CASCADE,
    hostname        TEXT NOT NULL UNIQUE,
    pubkey          TEXT NOT NULL UNIQUE,
    tunnel_ip       TEXT NOT NULL UNIQUE,
    public_endpoint TEXT NOT NULL,
    listen_port     INTEGER NOT NULL,
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS pis (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    district_id     INTEGER NOT NULL REFERENCES districts(id) ON DELETE CASCADE,
    hostname        TEXT NOT NULL UNIQUE,
    serial          TEXT NOT NULL UNIQUE,
    pubkey          TEXT NOT NULL UNIQUE,
    tunnel_ip       TEXT NOT NULL UNIQUE,
    real_subnets    TEXT NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('pending','active','revoked')),
    enrolled_at     TEXT NOT NULL DEFAULT (datetime('now')),
    approved_at     TEXT,
    revoked_at      TEXT
);

CREATE INDEX IF NOT EXISTS idx_pis_status ON pis(status);
CREATE INDEX IF NOT EXISTS idx_pis_district ON pis(district_id);
CREATE INDEX IF NOT EXISTS idx_zabbix_district ON zabbix_vms(district_id);
