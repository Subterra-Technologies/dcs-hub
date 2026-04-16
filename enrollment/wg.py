from __future__ import annotations

import subprocess
from pathlib import Path

WG_CONF = Path("/etc/wireguard/wg0.conf")
WG_INTERFACE = "wg0"


def render_peer_block(pubkey: str, tunnel_ip: str, virtual_subnet: str) -> str:
    raise NotImplementedError


def append_peer(peer_block: str) -> None:
    raise NotImplementedError


def remove_peer(pubkey: str) -> None:
    raise NotImplementedError


def syncconf() -> None:
    subprocess.run(
        ["wg", "syncconf", WG_INTERFACE, "/dev/stdin"],
        input=_strip_to_peers(WG_CONF.read_text()),
        text=True,
        check=True,
    )


def last_handshakes() -> dict[str, int]:
    raise NotImplementedError


def _strip_to_peers(conf_text: str) -> str:
    raise NotImplementedError
