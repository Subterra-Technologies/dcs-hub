"""End-to-end test of the enrollment service in a /tmp sandbox.

Runs the full flow without touching system wireguard:
- bootstrap hub keys + wg0.conf
- add school, issue token
- POST /v1/enroll as a fake Pi
- list-pending, approve (with SUBTERRA_SKIP_WG_SYNC=1)
- render wg0.conf and confirm the peer block is there
- idempotency check: same pubkey+serial+token returns same config
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> int:
    sandbox = Path(tempfile.mkdtemp(prefix="subterra-test-"))
    state_dir = sandbox / "state"
    wg_dir = sandbox / "wg"
    state_dir.mkdir()
    wg_dir.mkdir()
    db_path = state_dir / "state.db"
    wg_conf = wg_dir / "wg0.conf"
    hub_priv = wg_dir / "hub.key"
    hub_pub = wg_dir / "hub.pubkey"

    env = {
        **os.environ,
        "SUBTERRA_DB": str(db_path),
        "SUBTERRA_WG_CONF": str(wg_conf),
        "SUBTERRA_HUB_PRIVKEY": str(hub_priv),
        "SUBTERRA_HUB_PUBKEY": str(hub_pub),
        "SUBTERRA_WG_ENDPOINT": "hub.test:51820",
        "SUBTERRA_SKIP_WG_SYNC": "1",
    }

    def run_cli(*args: str) -> subprocess.CompletedProcess:
        r = subprocess.run(
            [sys.executable, "-m", "enrollment.admin_cli", *args],
            env=env,
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            print(f"CLI {args} failed rc={r.returncode}", file=sys.stderr)
            print(f"stdout: {r.stdout}", file=sys.stderr)
            print(f"stderr: {r.stderr}", file=sys.stderr)
            raise SystemExit(1)
        return r

    try:
        run_cli("bootstrap")
        assert wg_conf.exists(), "wg0.conf not created by bootstrap"
        assert hub_priv.exists()
        assert hub_pub.exists()

        run_cli("add-school", "oakridge", "Oakridge ISD")
        issued = run_cli("issue-token", "oakridge", "--valid-days", "7")
        token = issued.stdout.strip().splitlines()[-1]
        assert len(token) > 20, f"token looks wrong: {token!r}"

        os.environ.update(env)
        for m in list(sys.modules):
            if m.startswith("enrollment"):
                del sys.modules[m]
        from fastapi.testclient import TestClient

        from enrollment.main import app

        client = TestClient(app)

        hs = client.get("/healthz")
        assert hs.status_code == 200

        pi_priv = subprocess.run(
            ["wg", "genkey"], capture_output=True, text=True, check=True
        ).stdout.strip()
        pi_pub = subprocess.run(
            ["wg", "pubkey"],
            input=pi_priv,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

        payload = {
            "serial": "PI000TESTSERIAL1",
            "pubkey": pi_pub,
            "enroll_token": token,
            "detected_subnets": ["192.168.1.0/24", "192.168.10.0/24"],
        }
        resp = client.post("/v1/enroll", json=payload)
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["hostname"] == "oakridge-pi01", body
        assert body["assigned_tunnel_ip"] == "10.200.0.2/32", body
        assert body["virtual_subnet"] == "10.100.0.0/16", body
        assert body["real_subnets"] == payload["detected_subnets"]
        assert body["subnet_mappings"] == [
            {"virtual": "10.100.0.0/24", "real": "192.168.1.0/24"},
            {"virtual": "10.100.1.0/24", "real": "192.168.10.0/24"},
        ], body["subnet_mappings"]

        idem = client.post("/v1/enroll", json=payload)
        assert idem.status_code == 200, idem.text
        assert idem.json() == body, "idempotent replay should return identical config"

        bad = client.post(
            "/v1/enroll",
            json={**payload, "serial": "DIFFERENT", "pubkey": pi_pub},
        )
        assert bad.status_code == 409, (bad.status_code, bad.text)

        pending = run_cli("list-pending")
        assert "oakridge-pi01" in pending.stdout, pending.stdout
        assert "PI000TESTSERIAL1" in pending.stdout, pending.stdout

        approve = run_cli("approve", "PI000TESTSERIAL1")
        assert "approved" in approve.stdout, approve.stdout

        rendered = wg_conf.read_text()
        assert "[Peer]" in rendered, rendered
        assert pi_pub in rendered, rendered
        assert "10.200.0.2/32" in rendered, rendered
        assert "10.100.0.0/16" in rendered, rendered
        assert "oakridge-pi01" in rendered, rendered

        token2 = run_cli("issue-token", "oakridge").stdout.strip().splitlines()[-1]
        pi2_priv = subprocess.run(
            ["wg", "genkey"], capture_output=True, text=True, check=True
        ).stdout.strip()
        pi2_pub = subprocess.run(
            ["wg", "pubkey"], input=pi2_priv, capture_output=True, text=True, check=True
        ).stdout.strip()
        # Mixed 192.168.* and 10.* in one district — third-octet collision case
        # that the old mapping code got wrong.
        mixed_subnets = [
            "192.168.1.0/24",
            "10.5.0.0/24",
            "10.10.0.0/24",
            "192.168.10.0/24",
        ]
        resp2 = client.post(
            "/v1/enroll",
            json={
                "serial": "PI000TESTSERIAL2",
                "pubkey": pi2_pub,
                "enroll_token": token2,
                "detected_subnets": mixed_subnets,
            },
        )
        assert resp2.status_code == 200, resp2.text
        b2 = resp2.json()
        assert b2["hostname"] == "oakridge-pi02", b2
        assert b2["assigned_tunnel_ip"] == "10.200.0.3/32", b2
        assert b2["virtual_subnet"] == "10.101.0.0/16", b2
        # Sequential allocation in the district's /16, no collisions.
        assert b2["subnet_mappings"] == [
            {"virtual": "10.101.0.0/24", "real": "192.168.1.0/24"},
            {"virtual": "10.101.1.0/24", "real": "10.5.0.0/24"},
            {"virtual": "10.101.2.0/24", "real": "10.10.0.0/24"},
            {"virtual": "10.101.3.0/24", "real": "192.168.10.0/24"},
        ], b2["subnet_mappings"]
        virts = [m["virtual"] for m in b2["subnet_mappings"]]
        assert len(set(virts)) == len(virts), f"virtual slice collision: {virts}"

        rev = run_cli("revoke", "PI000TESTSERIAL1")
        assert "revoked" in rev.stdout, rev.stdout
        rendered_after = wg_conf.read_text()
        assert pi_pub not in rendered_after, rendered_after

        run_cli("approve", "PI000TESTSERIAL2")
        rendered2 = wg_conf.read_text()
        assert pi2_pub in rendered2 and "10.101.0.0/16" in rendered2, rendered2

        bad_token = client.post(
            "/v1/enroll",
            json={
                "serial": "PI000TESTSERIAL3",
                "pubkey": pi2_pub,
                "enroll_token": "not-a-real-token-0000000000",
                "detected_subnets": [],
            },
        )
        assert bad_token.status_code == 403, bad_token.text

        print("OK: enrollment flow green")
        return 0
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
