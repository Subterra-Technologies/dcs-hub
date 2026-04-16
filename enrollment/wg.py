from __future__ import annotations

import os
import sqlite3
import subprocess
import tempfile
from pathlib import Path

WG_CONF = Path(os.environ.get("SUBTERRA_WG_CONF", "/etc/wireguard/wg0.conf"))
WG_INTERFACE = os.environ.get("SUBTERRA_WG_IFACE", "wg0")

PEERS_BEGIN = "# === PEERS BEGIN ==="
PEERS_END = "# === PEERS END ==="


def render_peer_block(hostname: str, pubkey: str, tunnel_ip: str, virtual_subnet: str) -> str:
    return (
        f"# {hostname}\n"
        f"[Peer]\n"
        f"PublicKey = {pubkey}\n"
        f"AllowedIPs = {tunnel_ip}, {virtual_subnet}\n"
    )


def _read_conf() -> str:
    return WG_CONF.read_text()


def _write_conf_atomic(new_text: str) -> None:
    fd, tmp_path = tempfile.mkstemp(dir=WG_CONF.parent, prefix=".wg0.conf.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(new_text)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, WG_CONF)
    except Exception:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
        raise


def replace_peers_section(conf_text: str, peer_blocks: list[str]) -> str:
    i = conf_text.find(PEERS_BEGIN)
    j = conf_text.find(PEERS_END)
    if i == -1 or j == -1 or j < i:
        raise RuntimeError(
            f"wg0.conf missing '{PEERS_BEGIN}'/'{PEERS_END}' markers at {WG_CONF}"
        )
    head = conf_text[: i + len(PEERS_BEGIN)]
    tail = conf_text[j:]
    if peer_blocks:
        body = "\n\n" + "\n".join(peer_blocks) + "\n"
    else:
        body = "\n"
    return head + body + tail


def render_and_write_conf(conn: sqlite3.Connection) -> None:
    rows = conn.execute(
        "SELECT hostname, pubkey, tunnel_ip, virtual_subnet "
        "FROM peers WHERE status = 'active' ORDER BY id"
    ).fetchall()
    blocks = [
        render_peer_block(r["hostname"], r["pubkey"], r["tunnel_ip"], r["virtual_subnet"])
        for r in rows
    ]
    new_text = replace_peers_section(_read_conf(), blocks)
    _write_conf_atomic(new_text)


def syncconf() -> None:
    stripped = subprocess.run(
        ["wg-quick", "strip", WG_INTERFACE],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    subprocess.run(
        ["wg", "syncconf", WG_INTERFACE, "/dev/stdin"],
        input=stripped,
        text=True,
        check=True,
    )


def apply(conn: sqlite3.Connection) -> None:
    render_and_write_conf(conn)
    if os.environ.get("SUBTERRA_SKIP_WG_SYNC") == "1":
        return
    syncconf()


def last_handshakes() -> dict[str, int]:
    out = subprocess.run(
        ["wg", "show", WG_INTERFACE, "latest-handshakes"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    result: dict[str, int] = {}
    for line in out.strip().splitlines():
        parts = line.split()
        if len(parts) == 2:
            pubkey, ts = parts
            result[pubkey] = int(ts)
    return result
