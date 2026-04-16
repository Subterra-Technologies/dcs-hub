from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

import typer

from . import allocator, db, tokens, wg

DB_PATH = Path(os.environ.get("SUBTERRA_DB", "/var/lib/subterra-hub/state.db"))

app = typer.Typer(help="subterra-wg-hub admin CLI", no_args_is_help=True)


@app.command("init")
def init() -> None:
    """Initialize the coordinator DB. Safe to re-run."""
    db.initialize(DB_PATH)
    typer.echo(f"db ready at {DB_PATH}")


@app.command("add-district")
def add_district(slug: str, display_name: str, contact_email: str = "") -> None:
    conn = db.connect(DB_PATH)
    try:
        with db.transaction(conn):
            subnet = allocator.allocate_district_tunnel(conn)
            conn.execute(
                "INSERT INTO districts (slug, display_name, contact_email, tunnel_subnet) "
                "VALUES (?, ?, ?, ?)",
                (slug, display_name, contact_email or None, subnet),
            )
        typer.echo(f"district {slug}: tunnel /29 = {subnet}")
    finally:
        conn.close()


@app.command("register-zabbix")
def register_zabbix(
    district_slug: str,
    zabbix_hostname: str,
    pubkey: str,
    public_endpoint: str,
    listen_port: int = 51820,
) -> None:
    """Record a Zabbix VM for a district. public_endpoint is what the Pi dials
    (e.g. district-a.hub.yourdomain.com:51821)."""
    conn = db.connect(DB_PATH)
    try:
        district = conn.execute(
            "SELECT id FROM districts WHERE slug = ?", (district_slug,)
        ).fetchone()
        if district is None:
            raise typer.BadParameter(f"no district '{district_slug}'")
        with db.transaction(conn):
            tunnel_ip = allocator.allocate_zabbix_tunnel_ip(conn, district["id"])
            conn.execute(
                "INSERT INTO zabbix_vms "
                "(district_id, hostname, pubkey, tunnel_ip, public_endpoint, listen_port) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (
                    district["id"],
                    zabbix_hostname,
                    pubkey,
                    tunnel_ip,
                    public_endpoint,
                    listen_port,
                ),
            )
        typer.echo(
            f"registered {zabbix_hostname} in {district_slug}: "
            f"tunnel {tunnel_ip}, dial-in {public_endpoint}"
        )
    finally:
        conn.close()


@app.command("issue-token")
def issue_token(district_slug: str, valid_days: int = 14) -> None:
    conn = db.connect(DB_PATH)
    try:
        district = conn.execute(
            "SELECT id FROM districts WHERE slug = ?", (district_slug,)
        ).fetchone()
        if district is None:
            raise typer.BadParameter(f"no district '{district_slug}'")
        raw = tokens.generate()
        token_hash = tokens.hash_token(raw)
        expires = (datetime.now(timezone.utc) + timedelta(days=valid_days)).strftime(
            "%Y-%m-%d %H:%M:%S"
        )
        with db.transaction(conn):
            conn.execute(
                "INSERT INTO enroll_tokens (token_hash, district_id, expires_at) "
                "VALUES (?, ?, ?)",
                (token_hash, district["id"], expires),
            )
        typer.echo(raw)
    finally:
        conn.close()


@app.command("list-pending")
def list_pending() -> None:
    conn = db.connect(DB_PATH)
    try:
        rows = conn.execute(
            "SELECT p.id, p.hostname, p.serial, p.tunnel_ip, p.enrolled_at, "
            "       d.slug AS district "
            "FROM pis p JOIN districts d ON d.id = p.district_id "
            "WHERE p.status = 'pending' ORDER BY p.enrolled_at"
        ).fetchall()
        if not rows:
            typer.echo("no pending Pis")
            return
        for r in rows:
            typer.echo(
                f"{r['id']:>4}  {r['district']:<20}  {r['hostname']:<24}  "
                f"{r['serial']:<20}  {r['tunnel_ip']:<18}  {r['enrolled_at']}"
            )
    finally:
        conn.close()


@app.command("approve")
def approve(serial: str) -> None:
    conn = db.connect(DB_PATH)
    try:
        with db.transaction(conn):
            row = conn.execute(
                "SELECT id, status FROM pis WHERE serial = ?", (serial,)
            ).fetchone()
            if row is None:
                raise typer.BadParameter(f"no Pi with serial '{serial}'")
            if row["status"] != "pending":
                raise typer.BadParameter(
                    f"Pi is '{row['status']}', only 'pending' can be approved"
                )
            conn.execute(
                "UPDATE pis SET status = 'active', approved_at = datetime('now') "
                "WHERE id = ?",
                (row["id"],),
            )
        typer.echo(f"approved {serial}")
        typer.echo(
            "Next: re-apply WG config on each Zabbix VM in this district "
            "(subterra-hub show-zabbix-config <hostname>)."
        )
    finally:
        conn.close()


@app.command("revoke")
def revoke(serial: str) -> None:
    conn = db.connect(DB_PATH)
    try:
        with db.transaction(conn):
            row = conn.execute(
                "SELECT id FROM pis WHERE serial = ?", (serial,)
            ).fetchone()
            if row is None:
                raise typer.BadParameter(f"no Pi with serial '{serial}'")
            conn.execute(
                "UPDATE pis SET status = 'revoked', revoked_at = datetime('now') "
                "WHERE id = ?",
                (row["id"],),
            )
        typer.echo(f"revoked {serial}")
    finally:
        conn.close()


@app.command("show-pi-config")
def show_pi_config(serial: str) -> None:
    """Print wg0.conf the Pi should have (PrivateKey is a placeholder)."""
    conn = db.connect(DB_PATH)
    try:
        pi = conn.execute(
            "SELECT p.hostname, p.tunnel_ip, p.district_id FROM pis p "
            "WHERE p.serial = ?",
            (serial,),
        ).fetchone()
        if pi is None:
            raise typer.BadParameter(f"no Pi with serial '{serial}'")
        zabbixes = conn.execute(
            "SELECT pubkey, public_endpoint, tunnel_ip FROM zabbix_vms "
            "WHERE district_id = ? ORDER BY id",
            (pi["district_id"],),
        ).fetchall()
        peers = [
            {
                "pubkey": z["pubkey"],
                "endpoint": z["public_endpoint"],
                "tunnel_ip": z["tunnel_ip"].split("/")[0] + "/32",
            }
            for z in zabbixes
        ]
        typer.echo(wg.render_pi_config(
            pi_privkey_placeholder="<PI_PRIVATE_KEY>",
            pi_tunnel_ip=pi["tunnel_ip"],
            peers=peers,
        ))
    finally:
        conn.close()


@app.command("show-zabbix-config")
def show_zabbix_config(hostname: str) -> None:
    """Print the wg0.conf a Zabbix VM should run. PrivateKey placeholder."""
    conn = db.connect(DB_PATH)
    try:
        zv = conn.execute(
            "SELECT id FROM zabbix_vms WHERE hostname = ?", (hostname,)
        ).fetchone()
        if zv is None:
            raise typer.BadParameter(f"no zabbix VM '{hostname}'")
        typer.echo(wg.render_zabbix_config(conn, zv["id"], "<ZABBIX_PRIVATE_KEY>"))
    finally:
        conn.close()


@app.command("list-districts")
def list_districts() -> None:
    conn = db.connect(DB_PATH)
    try:
        rows = conn.execute(
            "SELECT d.slug, d.display_name, d.tunnel_subnet, "
            "       (SELECT COUNT(*) FROM zabbix_vms WHERE district_id=d.id) AS n_zabbix, "
            "       (SELECT COUNT(*) FROM pis WHERE district_id=d.id AND status='active') AS n_pis "
            "FROM districts d ORDER BY d.slug"
        ).fetchall()
        for r in rows:
            typer.echo(
                f"{r['slug']:<20}  {r['tunnel_subnet']:<18}  "
                f"zabbix={r['n_zabbix']}  active-pis={r['n_pis']}  "
                f"{r['display_name']}"
            )
    finally:
        conn.close()


if __name__ == "__main__":
    app()
