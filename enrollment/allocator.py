from __future__ import annotations

import ipaddress
import sqlite3

TUNNEL_OVERLAY = ipaddress.ip_network("10.200.0.0/16")
DISTRICT_PREFIX = 29
PI_HOST_OFFSET = 1


class AllocationError(RuntimeError):
    pass


def allocate_district_tunnel(conn: sqlite3.Connection) -> str:
    """First-free /29 inside TUNNEL_OVERLAY, sequential, skipping any subnet
    already assigned to a district (active or revoked — reuse is risky)."""
    taken = {
        ipaddress.ip_network(row["tunnel_subnet"])
        for row in conn.execute("SELECT tunnel_subnet FROM districts")
    }
    for candidate in TUNNEL_OVERLAY.subnets(new_prefix=DISTRICT_PREFIX):
        if candidate not in taken:
            return str(candidate)
    raise AllocationError("tunnel overlay exhausted; expand TUNNEL_OVERLAY")


def pi_tunnel_ip(district_subnet: str) -> str:
    """Pi always takes the first host IP in the district's /29."""
    net = ipaddress.ip_network(district_subnet)
    return f"{net.network_address + PI_HOST_OFFSET}/{net.prefixlen}"


def allocate_zabbix_tunnel_ip(conn: sqlite3.Connection, district_id: int) -> str:
    """Next free host IP in the district's /29 after the Pi slot."""
    row = conn.execute(
        "SELECT tunnel_subnet FROM districts WHERE id = ?", (district_id,)
    ).fetchone()
    if row is None:
        raise AllocationError(f"district {district_id} not found")
    net = ipaddress.ip_network(row["tunnel_subnet"])
    taken = {
        ipaddress.ip_interface(r["tunnel_ip"]).ip
        for r in conn.execute(
            "SELECT tunnel_ip FROM zabbix_vms WHERE district_id = ?", (district_id,)
        )
    }
    taken.add(net.network_address + PI_HOST_OFFSET)  # Pi slot reserved
    for host in net.hosts():
        if host not in taken:
            return f"{host}/{net.prefixlen}"
    raise AllocationError(
        f"district /29 {net} full (max {net.num_addresses - 2 - 1} Zabbix VMs)"
    )
