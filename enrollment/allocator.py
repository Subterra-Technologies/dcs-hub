from __future__ import annotations

import ipaddress
import sqlite3

TUNNEL_OVERLAY = ipaddress.ip_network("10.200.0.0/16")
TUNNEL_HUB_IP = ipaddress.ip_address("10.200.0.1")
VIRTUAL_POOL_START = 100
VIRTUAL_POOL_END = 199


def allocate_tunnel_ip(conn: sqlite3.Connection) -> str:
    raise NotImplementedError


def allocate_virtual_subnet(conn: sqlite3.Connection) -> str:
    raise NotImplementedError
