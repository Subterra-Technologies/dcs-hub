from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

import typer

from . import db, tokens, wg

DB_PATH = Path(os.environ.get("SUBTERRA_DB", "/var/lib/subterra-hub/state.db"))
WG_CONF_TEMPLATE = Path(__file__).parent.parent / "config" / "wg0.conf.template"
WG_CONF = Path(os.environ.get("SUBTERRA_WG_CONF", "/etc/wireguard/wg0.conf"))
WG_PRIVKEY = Path(os.environ.get("SUBTERRA_HUB_PRIVKEY", "/etc/wireguard/hub.key"))
WG_PUBKEY = Path(os.environ.get("SUBTERRA_HUB_PUBKEY", "/etc/wireguard/hub.pubkey"))

app = typer.Typer(help="subterra-wg-hub admin CLI", no_args_is_help=True)


@app.command("bootstrap")
def bootstrap() -> None:
    """Generate hub keypair and write initial wg0.conf from template."""
    db.initialize(DB_PATH)
    if not WG_PRIVKEY.exists():
        priv = subprocess.run(
            ["wg", "genkey"], capture_output=True, text=True, check=True
        ).stdout.strip()
        WG_PRIVKEY.write_text(priv + "\n")
        os.chmod(WG_PRIVKEY, 0o600)
        pub = subprocess.run(
            ["wg", "pubkey"], input=priv, capture_output=True, text=True, check=True
        ).stdout.strip()
        WG_PUBKEY.write_text(pub + "\n")
        os.chmod(WG_PUBKEY, 0o644)
        typer.echo(f"generated hub keypair -> {WG_PRIVKEY}, {WG_PUBKEY}")
    if not WG_CONF.exists():
        priv = WG_PRIVKEY.read_text().strip()
        conf = WG_CONF_TEMPLATE.read_text().replace("__HUB_PRIVKEY__", priv)
        WG_CONF.write_text(conf)
        os.chmod(WG_CONF, 0o600)
        typer.echo(f"wrote {WG_CONF}")
    typer.echo("bootstrap complete")


@app.command("add-school")
def add_school(slug: str, display_name: str, contact_email: str = "") -> None:
    conn = db.connect(DB_PATH)
    try:
        with db.transaction(conn):
            conn.execute(
                "INSERT INTO schools (slug, display_name, contact_email) VALUES (?, ?, ?)",
                (slug, display_name, contact_email or None),
            )
        typer.echo(f"added school {slug}")
    finally:
        conn.close()


@app.command("issue-token")
def issue_token(school_slug: str, valid_days: int = 14) -> None:
    conn = db.connect(DB_PATH)
    try:
        school = conn.execute(
            "SELECT id FROM schools WHERE slug = ?", (school_slug,)
        ).fetchone()
        if school is None:
            raise typer.BadParameter(f"no school with slug '{school_slug}'")
        raw = tokens.generate()
        token_hash = tokens.hash_token(raw)
        expires = (datetime.now(timezone.utc) + timedelta(days=valid_days)).strftime(
            "%Y-%m-%d %H:%M:%S"
        )
        with db.transaction(conn):
            conn.execute(
                "INSERT INTO enroll_tokens (token_hash, school_id, expires_at) "
                "VALUES (?, ?, ?)",
                (token_hash, school["id"], expires),
            )
        typer.echo(raw)
    finally:
        conn.close()


@app.command("list-pending")
def list_pending() -> None:
    conn = db.connect(DB_PATH)
    try:
        rows = conn.execute(
            "SELECT p.id, p.hostname, p.serial, p.tunnel_ip, p.virtual_subnet, "
            "       p.enrolled_at, s.slug AS school "
            "FROM peers p JOIN schools s ON s.id = p.school_id "
            "WHERE p.status = 'pending' ORDER BY p.enrolled_at"
        ).fetchall()
        if not rows:
            typer.echo("no pending peers")
            return
        for r in rows:
            typer.echo(
                f"{r['id']:>4}  {r['school']:<20}  {r['hostname']:<24}  "
                f"{r['serial']:<16}  {r['tunnel_ip']:<18}  {r['virtual_subnet']:<18}  "
                f"{r['enrolled_at']}"
            )
    finally:
        conn.close()


@app.command("approve")
def approve(serial: str) -> None:
    conn = db.connect(DB_PATH)
    try:
        with db.transaction(conn):
            row = conn.execute(
                "SELECT id, status FROM peers WHERE serial = ?", (serial,)
            ).fetchone()
            if row is None:
                raise typer.BadParameter(f"no peer with serial '{serial}'")
            if row["status"] != "pending":
                raise typer.BadParameter(
                    f"peer is '{row['status']}', only 'pending' can be approved"
                )
            conn.execute(
                "UPDATE peers SET status = 'active', approved_at = datetime('now') "
                "WHERE id = ?",
                (row["id"],),
            )
        wg.apply(conn)
        typer.echo(f"approved {serial}")
    finally:
        conn.close()


@app.command("revoke")
def revoke(serial: str) -> None:
    conn = db.connect(DB_PATH)
    try:
        with db.transaction(conn):
            row = conn.execute(
                "SELECT id FROM peers WHERE serial = ?", (serial,)
            ).fetchone()
            if row is None:
                raise typer.BadParameter(f"no peer with serial '{serial}'")
            conn.execute(
                "UPDATE peers SET status = 'revoked', revoked_at = datetime('now') "
                "WHERE id = ?",
                (row["id"],),
            )
        wg.apply(conn)
        typer.echo(f"revoked {serial}")
    finally:
        conn.close()


@app.command("handshakes")
def handshakes() -> None:
    conn = db.connect(DB_PATH)
    try:
        hs = wg.last_handshakes()
        rows = conn.execute(
            "SELECT hostname, pubkey, status FROM peers WHERE status = 'active' "
            "ORDER BY hostname"
        ).fetchall()
        now = int(datetime.now(timezone.utc).timestamp())
        for r in rows:
            last = hs.get(r["pubkey"], 0)
            age = "never" if last == 0 else f"{now - last}s ago"
            typer.echo(f"{r['hostname']:<24}  {age}")
    finally:
        conn.close()


@app.command("dump-conf")
def dump_conf() -> None:
    """Render wg0.conf from the DB without applying (debugging)."""
    conn = db.connect(DB_PATH)
    try:
        rows = conn.execute(
            "SELECT hostname, pubkey, tunnel_ip, virtual_subnet "
            "FROM peers WHERE status = 'active' ORDER BY id"
        ).fetchall()
        for r in rows:
            typer.echo(
                wg.render_peer_block(
                    r["hostname"], r["pubkey"], r["tunnel_ip"], r["virtual_subnet"]
                )
            )
    finally:
        conn.close()


if __name__ == "__main__":
    app()
