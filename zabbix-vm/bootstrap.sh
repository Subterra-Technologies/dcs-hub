#!/usr/bin/env bash
# Bootstrap a Zabbix VM as the DC-side WG endpoint for one district.
#
# Run once on a fresh Debian 12+ Zabbix VM. Installs wireguard, generates a
# keypair, sets sysctls, opens firewall, and prints the pubkey + next-step
# instructions for ops to register the VM with the coordinator.
#
# After ops runs `subterra-hub register-zabbix` on the coordinator, come back
# and run `apply-config.sh` with the coordinator-rendered config.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "bootstrap.sh must run as root (try: sudo $0)" >&2
    exit 1
fi

WG_DIR=/etc/wireguard
PRIVKEY="${WG_DIR}/privatekey"
PUBKEY="${WG_DIR}/publickey"
LISTEN_PORT="${1:-51820}"

echo "[1/4] installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools ufw

echo "[2/4] enabling IP forwarding (for routing school real subnets via wg0)"
cat > /etc/sysctl.d/99-subterra-zabbix.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

echo "[3/4] generating WG keypair (idempotent)"
mkdir -p "${WG_DIR}"
chmod 700 "${WG_DIR}"
if [[ ! -s "${PRIVKEY}" ]]; then
    ( umask 077 && wg genkey > "${PRIVKEY}" )
    wg pubkey < "${PRIVKEY}" > "${PUBKEY}"
fi
chmod 600 "${PRIVKEY}"
chmod 644 "${PUBKEY}"

echo "[4/4] opening firewall for WG"
ufw --force enable >/dev/null
ufw allow "${LISTEN_PORT}/udp" >/dev/null
ufw allow OpenSSH >/dev/null

PUB_RAW="$(cat "${PUBKEY}")"

cat <<EOF

============================================================
Bootstrap complete. WG keypair at ${WG_DIR}.

Your public key is:
  ${PUB_RAW}

Next, have a coordinator admin run (on the hub):

  sudo -u subterra-hub /opt/subterra-hub/.venv/bin/subterra-hub \\
    register-zabbix <district-slug> $(hostname) '${PUB_RAW}' \\
      <public-host-or-ip>:${LISTEN_PORT} --listen-port ${LISTEN_PORT}

Then on the hub, render this VM's config:

  sudo -u subterra-hub /opt/subterra-hub/.venv/bin/subterra-hub \\
    show-zabbix-config $(hostname)

Paste that config (stdin) into this VM via:

  sudo /path/to/apply-config.sh

Edge router: port-forward UDP ${LISTEN_PORT} from your public IP to this VM.
DNS: point the hostname you used in --public-host at the public IP.
============================================================
EOF
