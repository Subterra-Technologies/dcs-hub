from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException

from . import allocator, db, tokens
from .models import EnrollRequest, EnrollResponse, WGPeer

DB_PATH = Path(os.environ.get("SUBTERRA_DB", "/var/lib/subterra-hub/state.db"))

app = FastAPI(title="subterra-wg-hub enrollment", version="0.2.0")


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
                "SELECT token_hash, district_id, expires_at, consumed_at "
                "FROM enroll_tokens WHERE token_hash = ?",
                (token_hash,),
            ).fetchone()
            if token_row is None:
                raise HTTPException(status_code=403, detail="unknown enroll_token")
            if token_row["consumed_at"] is not None:
                existing = conn.execute(
                    "SELECT hostname, tunnel_ip, real_subnets, district_id FROM pis "
                    "WHERE serial = ? AND pubkey = ?",
                    (req.serial, req.pubkey),
                ).fetchone()
                if existing is not None:
                    return _build_response(conn, existing)
                raise HTTPException(status_code=409, detail="enroll_token already consumed")
            if token_row["expires_at"] < _now_iso():
                raise HTTPException(status_code=403, detail="enroll_token expired")

            district_id = token_row["district_id"]
            district = conn.execute(
                "SELECT slug, tunnel_subnet FROM districts WHERE id = ?",
                (district_id,),
            ).fetchone()
            if district is None:
                raise HTTPException(status_code=500, detail="district missing for token")

            seq = conn.execute(
                "SELECT COUNT(*) AS n FROM pis WHERE district_id = ?", (district_id,)
            ).fetchone()["n"]
            hostname = f"{district['slug']}-pi{seq + 1:02d}"
            tunnel_ip = allocator.pi_tunnel_ip(district["tunnel_subnet"])

            conn.execute(
                "INSERT INTO pis "
                "(district_id, hostname, serial, pubkey, tunnel_ip, "
                " real_subnets, status) "
                "VALUES (?, ?, ?, ?, ?, ?, 'pending')",
                (
                    district_id,
                    hostname,
                    req.serial,
                    req.pubkey,
                    tunnel_ip,
                    json.dumps(req.detected_subnets),
                ),
            )
            conn.execute(
                "UPDATE enroll_tokens SET consumed_at = ? WHERE token_hash = ?",
                (_now_iso(), token_hash),
            )
            new_row = conn.execute(
                "SELECT hostname, tunnel_ip, real_subnets, district_id FROM pis "
                "WHERE serial = ?",
                (req.serial,),
            ).fetchone()
        return _build_response(conn, new_row)
    finally:
        conn.close()


def _build_response(conn, pi_row) -> EnrollResponse:
    district = conn.execute(
        "SELECT tunnel_subnet FROM districts WHERE id = ?", (pi_row["district_id"],)
    ).fetchone()
    zabbixes = conn.execute(
        "SELECT pubkey, public_endpoint, tunnel_ip FROM zabbix_vms "
        "WHERE district_id = ? ORDER BY id",
        (pi_row["district_id"],),
    ).fetchall()
    peers = [
        WGPeer(
            pubkey=z["pubkey"],
            endpoint=z["public_endpoint"],
            tunnel_ip=z["tunnel_ip"].split("/")[0] + "/32",
        )
        for z in zabbixes
    ]
    return EnrollResponse(
        hostname=pi_row["hostname"],
        assigned_tunnel_ip=pi_row["tunnel_ip"],
        district_subnet=district["tunnel_subnet"],
        real_subnets=json.loads(pi_row["real_subnets"]),
        peers=peers,
    )


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def serve() -> None:
    import uvicorn

    uvicorn.run(
        "enrollment.main:app",
        host=os.environ.get("SUBTERRA_HOST", "127.0.0.1"),
        port=int(os.environ.get("SUBTERRA_PORT", "8080")),
    )
