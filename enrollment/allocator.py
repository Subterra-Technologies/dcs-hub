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


def allocate_subnet_mappings(
    virtual_subnet_cidr: str, real_subnets: list[str]
) -> tuple[list[dict[str, str]], list[str]]:
    """Map each real subnet to a sequentially-allocated matching-prefix slice
    inside the district's virtual /16. Returns (mappings, skipped_reasons)."""
    virt_net = ipaddress.ip_network(virtual_subnet_cidr)
    used: set[ipaddress.IPv4Network] = set()
    mappings: list[dict[str, str]] = []
    skipped: list[str] = []

    for raw in real_subnets:
        try:
            real_net = ipaddress.ip_network(raw, strict=False)
        except ValueError:
            skipped.append(f"{raw}: not a valid CIDR")
            continue

        if real_net.prefixlen <= virt_net.prefixlen:
            skipped.append(
                f"{raw}: prefix /{real_net.prefixlen} does not fit inside "
                f"virtual {virtual_subnet_cidr}"
            )
            continue

        slice_iter = virt_net.subnets(new_prefix=real_net.prefixlen)
        chosen: ipaddress.IPv4Network | None = None
        for candidate in slice_iter:
            if not any(candidate.overlaps(u) for u in used):
                chosen = candidate
                break
        if chosen is None:
            skipped.append(
                f"{raw}: no free /{real_net.prefixlen} slice in {virtual_subnet_cidr}"
            )
            continue
        used.add(chosen)
        mappings.append({"virtual": str(chosen), "real": str(real_net)})

    return mappings, skipped
