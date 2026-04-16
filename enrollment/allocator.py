from __future__ import annotations

import ipaddress
import sqlite3

TUNNEL_OVERLAY = ipaddress.ip_network("10.200.0.0/16")
TUNNEL_HUB_IP = ipaddress.IPv4Address("10.200.0.1")
TUNNEL_FIRST_PEER = ipaddress.IPv4Address("10.200.0.2")
TUNNEL_LAST_PEER = ipaddress.IPv4Address("10.200.255.254")

VIRTUAL_SECOND_OCTET_START = 100
VIRTUAL_SECOND_OCTET_END = 199


class AllocationError(RuntimeError):
    pass


def allocate_tunnel_ip(conn: sqlite3.Connection) -> str:
    taken = {
        row["tunnel_ip"]
        for row in conn.execute("SELECT tunnel_ip FROM peers WHERE status != 'revoked'")
    }
    current = TUNNEL_FIRST_PEER
    while current <= TUNNEL_LAST_PEER:
        candidate = f"{current}/32"
        if candidate not in taken:
            return candidate
        current += 1
    raise AllocationError("tunnel /16 exhausted")


def allocate_virtual_subnet(conn: sqlite3.Connection) -> str:
    taken = {
        row["virtual_subnet"]
        for row in conn.execute(
            "SELECT virtual_subnet FROM peers WHERE status != 'revoked'"
        )
    }
    for octet in range(VIRTUAL_SECOND_OCTET_START, VIRTUAL_SECOND_OCTET_END + 1):
        candidate = f"10.{octet}.0.0/16"
        if candidate not in taken:
            return candidate
    raise AllocationError("virtual /16 pool exhausted")
