"""End-to-end test of the per-district coordinator in a /tmp sandbox.

Covers:
  init DB, add-district, register two Zabbix VMs (redundancy case),
  issue-token, POST /v1/enroll, approve, revoke, show-pi-config,
  show-zabbix-config, idempotent replay, bad-token 403, reuse 409.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> int:
    sandbox = Path(tempfile.mkdtemp(prefix="subterra-test-"))
    state_dir = sandbox / "state"
    state_dir.mkdir()
    db_path = state_dir / "state.db"

    env = {
        **os.environ,
        "SUBTERRA_DB": str(db_path),
    }

    def run_cli(*args: str) -> subprocess.CompletedProcess:
        r = subprocess.run(
            [sys.executable, "-m", "enrollment.admin_cli", *args],
            env=env, capture_output=True, text=True,
        )
        if r.returncode != 0:
            print(f"CLI {args} failed rc={r.returncode}", file=sys.stderr)
            print(f"stdout: {r.stdout}", file=sys.stderr)
            print(f"stderr: {r.stderr}", file=sys.stderr)
            raise SystemExit(1)
        return r

    try:
        run_cli("init")

        run_cli("add-district", "oakridge", "Oakridge ISD")
        districts = run_cli("list-districts").stdout
        assert "oakridge" in districts, districts
        assert "10.200.0.0/29" in districts, districts

        za_pub = _gen_pub()
        zb_pub = _gen_pub()
        run_cli(
            "register-zabbix", "oakridge", "zabbix-oakridge-a",
            za_pub, "zabbix-a.hub.test:51821", "--listen-port", "51821",
        )
        run_cli(
            "register-zabbix", "oakridge", "zabbix-oakridge-b",
            zb_pub, "zabbix-b.hub.test:51822", "--listen-port", "51822",
        )

        token = run_cli("issue-token", "oakridge").stdout.strip().splitlines()[-1]
        assert len(token) > 20

        os.environ.update(env)
        for m in list(sys.modules):
            if m.startswith("enrollment"):
                del sys.modules[m]
        from fastapi.testclient import TestClient

        from enrollment.main import app

        client = TestClient(app)
        assert client.get("/healthz").status_code == 200

        pi_pub = _gen_pub()
        payload = {
            "serial": "PI000TESTSERIAL1",
            "pubkey": pi_pub,
            "enroll_token": token,
            "detected_subnets": ["192.168.1.0/24", "10.50.0.0/24"],
        }
        resp = client.post("/v1/enroll", json=payload)
        assert resp.status_code == 200, resp.text
        body = resp.json()

        assert body["hostname"] == "oakridge-pi01", body
        assert body["assigned_tunnel_ip"] == "10.200.0.1/29", body
        assert body["district_subnet"] == "10.200.0.0/29", body
        assert body["real_subnets"] == payload["detected_subnets"]
        assert len(body["peers"]) == 2, body
        assert body["peers"][0]["pubkey"] == za_pub
        assert body["peers"][0]["endpoint"] == "zabbix-a.hub.test:51821"
        assert body["peers"][0]["tunnel_ip"] == "10.200.0.2/32"
        assert body["peers"][1]["pubkey"] == zb_pub
        assert body["peers"][1]["tunnel_ip"] == "10.200.0.3/32"

        idem = client.post("/v1/enroll", json=payload)
        assert idem.status_code == 200, idem.text
        assert idem.json() == body

        bad_serial = client.post(
            "/v1/enroll",
            json={**payload, "serial": "DIFFERENT"},
        )
        assert bad_serial.status_code == 409, bad_serial.text

        bad_token = client.post(
            "/v1/enroll",
            json={**payload, "serial": "PI000TESTSERIAL9", "enroll_token": "not-a-real-token-xxx"},
        )
        assert bad_token.status_code == 403, bad_token.text

        pending = run_cli("list-pending").stdout
        assert "oakridge-pi01" in pending
        assert "PI000TESTSERIAL1" in pending

        run_cli("approve", "PI000TESTSERIAL1")

        pi_conf = run_cli("show-pi-config", "PI000TESTSERIAL1").stdout
        assert "[Interface]" in pi_conf
        assert "Address = 10.200.0.1/29" in pi_conf
        assert pi_conf.count("[Peer]") == 2
        assert za_pub in pi_conf
        assert zb_pub in pi_conf
        assert "Endpoint = zabbix-a.hub.test:51821" in pi_conf
        assert "Endpoint = zabbix-b.hub.test:51822" in pi_conf
        assert "AllowedIPs = 10.200.0.2/32" in pi_conf
        assert "AllowedIPs = 10.200.0.3/32" in pi_conf

        za_conf = run_cli("show-zabbix-config", "zabbix-oakridge-a").stdout
        assert "Address = 10.200.0.2/29" in za_conf, za_conf
        assert "ListenPort = 51821" in za_conf, za_conf
        assert pi_pub in za_conf, za_conf
        assert "AllowedIPs = 10.200.0.1/32, 192.168.1.0/24, 10.50.0.0/24" in za_conf, za_conf

        zb_conf = run_cli("show-zabbix-config", "zabbix-oakridge-b").stdout
        assert "Address = 10.200.0.3/29" in zb_conf
        assert "ListenPort = 51822" in zb_conf
        assert pi_pub in zb_conf

        run_cli("add-district", "lincoln", "Lincoln Public Schools")
        districts2 = run_cli("list-districts").stdout
        assert "lincoln" in districts2
        assert "10.200.0.8/29" in districts2, districts2

        run_cli("revoke", "PI000TESTSERIAL1")
        za_conf_after = run_cli("show-zabbix-config", "zabbix-oakridge-a").stdout
        assert "no active Pi" in za_conf_after, za_conf_after

        print("OK: per-district enrollment flow green")
        return 0
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def _gen_pub() -> str:
    priv = subprocess.run(
        ["wg", "genkey"], capture_output=True, text=True, check=True
    ).stdout.strip()
    return subprocess.run(
        ["wg", "pubkey"], input=priv, capture_output=True, text=True, check=True
    ).stdout.strip()


if __name__ == "__main__":
    raise SystemExit(main())
