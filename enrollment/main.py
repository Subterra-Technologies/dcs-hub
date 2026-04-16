from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException

from . import allocator, db, tokens, wg
from .models import EnrollRequest, EnrollResponse

DB_PATH = Path(os.environ.get("SUBTERRA_DB", "/var/lib/subterra-hub/state.db"))
WG_ENDPOINT = os.environ.get("SUBTERRA_WG_ENDPOINT", "hub.example.com:51820")
WG_HUB_PUBKEY_FILE = Path(
    os.environ.get("SUBTERRA_HUB_PUBKEY", "/etc/wireguard/hub.pubkey")
)

app = FastAPI(title="subterra-wg-hub enrollment", version="0.1.0")


@app.on_event("startup")
def _startup() -> None:
    db.initialize(DB_PATH)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/v1/enroll", response_model=EnrollResponse)
def enroll(req: EnrollRequest) -> EnrollResponse:
    conn = db.connect(DB_PATH)
    try:
        with db.transaction(conn):
            token_hash = tokens.hash_token(req.enroll_token)
            token_row = conn.execute(
                "SELECT token_hash, school_id, expires_at, consumed_at "
                "FROM enroll_tokens WHERE token_hash = ?",
                (token_hash,),
            ).fetchone()
            if token_row is None:
                raise HTTPException(status_code=403, detail="unknown enroll_token")
            if token_row["consumed_at"] is not None:
                existing = conn.execute(
                    "SELECT hostname, tunnel_ip, virtual_subnet, real_subnets "
                    "FROM peers WHERE serial = ? AND pubkey = ?",
                    (req.serial, req.pubkey),
                ).fetchone()
                if existing is not None:
                    return _response_from_row(existing)
                raise HTTPException(status_code=409, detail="enroll_token already consumed")
            if token_row["expires_at"] < _now_iso():
                raise HTTPException(status_code=403, detail="enroll_token expired")

            school_id = token_row["school_id"]
            school = conn.execute(
                "SELECT slug FROM schools WHERE id = ?", (school_id,)
            ).fetchone()
            if school is None:
                raise HTTPException(status_code=500, detail="school missing for token")

            seq = conn.execute(
                "SELECT COUNT(*) AS n FROM peers WHERE school_id = ?", (school_id,)
            ).fetchone()["n"]
            hostname = f"{school['slug']}-pi{seq + 1:02d}"
            tunnel_ip = allocator.allocate_tunnel_ip(conn)
            virtual_subnet = allocator.allocate_virtual_subnet(conn)

            conn.execute(
                "INSERT INTO peers "
                "(school_id, hostname, serial, pubkey, tunnel_ip, virtual_subnet, "
                " real_subnets, status) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, 'pending')",
                (
                    school_id,
                    hostname,
                    req.serial,
                    req.pubkey,
                    tunnel_ip,
                    virtual_subnet,
                    json.dumps(req.detected_subnets),
                ),
            )
            conn.execute(
                "UPDATE enroll_tokens SET consumed_at = ? WHERE token_hash = ?",
                (_now_iso(), token_hash),
            )

        return EnrollResponse(
            wg_server_pubkey=_hub_pubkey(),
            wg_endpoint=WG_ENDPOINT,
            assigned_tunnel_ip=tunnel_ip,
            virtual_subnet=virtual_subnet,
            real_subnets=req.detected_subnets,
            hostname=hostname,
        )
    finally:
        conn.close()


def _response_from_row(row) -> EnrollResponse:
    return EnrollResponse(
        wg_server_pubkey=_hub_pubkey(),
        wg_endpoint=WG_ENDPOINT,
        assigned_tunnel_ip=row["tunnel_ip"],
        virtual_subnet=row["virtual_subnet"],
        real_subnets=json.loads(row["real_subnets"]),
        hostname=row["hostname"],
    )


def _hub_pubkey() -> str:
    return WG_HUB_PUBKEY_FILE.read_text().strip()


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def serve() -> None:
    import uvicorn

    uvicorn.run(
        "enrollment.main:app",
        host=os.environ.get("SUBTERRA_HOST", "127.0.0.1"),
        port=int(os.environ.get("SUBTERRA_PORT", "8080")),
    )
