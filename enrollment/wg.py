"""WireGuard config text generation.

The coordinator does NOT run a wg0 interface. It generates config text that
ops (or a future reconciler) applies on the Zabbix VM side, and that the Pi
writes to its own /etc/wireguard/wg0.conf at enrollment time.
"""
from __future__ import annotations

import sqlite3


def render_pi_config(
    *,
    pi_privkey_placeholder: str,
    pi_tunnel_ip: str,
    peers: list[dict[str, str]],
    persistent_keepalive: int = 25,
) -> str:
    lines = [
        "[Interface]",
        f"Address = {pi_tunnel_ip}",
        f"PrivateKey = {pi_privkey_placeholder}",
        "",
    ]
    for p in peers:
        lines.extend([
            "[Peer]",
            f"PublicKey = {p['pubkey']}",
            f"Endpoint = {p['endpoint']}",
            f"AllowedIPs = {p['tunnel_ip']}",
            f"PersistentKeepalive = {persistent_keepalive}",
            "",
        ])
    return "\n".join(lines)


def render_zabbix_config(
    conn: sqlite3.Connection, zabbix_id: int, privkey_placeholder: str
) -> str:
    zv = conn.execute(
        "SELECT z.hostname, z.tunnel_ip, z.listen_port, z.district_id, "
        "       d.tunnel_subnet "
        "FROM zabbix_vms z JOIN districts d ON d.id = z.district_id "
        "WHERE z.id = ?",
        (zabbix_id,),
    ).fetchone()
    if zv is None:
        raise ValueError(f"no zabbix_vm with id {zabbix_id}")

    pi = conn.execute(
        "SELECT pubkey, tunnel_ip, real_subnets FROM pis "
        "WHERE district_id = ? AND status = 'active' ORDER BY id",
        (zv["district_id"],),
    ).fetchone()

    lines = [
        f"# zabbix {zv['hostname']} (district_id={zv['district_id']})",
        "[Interface]",
        f"Address = {zv['tunnel_ip']}",
        f"PrivateKey = {privkey_placeholder}",
        f"ListenPort = {zv['listen_port']}",
        "",
    ]
    if pi is None:
        lines.append("# no active Pi in this district yet")
        return "\n".join(lines)

    import json

    real = json.loads(pi["real_subnets"])
    pi_tunnel_ip_no_mask = pi["tunnel_ip"].split("/")[0] + "/32"
    allowed = [pi_tunnel_ip_no_mask, *real]
    lines.extend([
        "[Peer]",
        f"PublicKey = {pi['pubkey']}",
        f"AllowedIPs = {', '.join(allowed)}",
        "PersistentKeepalive = 25",
        "",
    ])
    return "\n".join(lines)
