#!/usr/bin/env bash
# Provision a fresh Debian 12+ host as a Subterra WireGuard concentrator.
#
# Idempotent. Safe to re-run. Reads /etc/subterra-hub/setup.env if present;
# otherwise writes a template and exits so the operator can fill it in.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "setup.sh must run as root (try: sudo $0)" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE=/etc/subterra-hub/setup.env
INSTALL_DIR=/opt/subterra-hub
STATE_DIR=/var/lib/subterra-hub
WG_DIR=/etc/wireguard
SERVICE_USER=subterra-hub

mkdir -p "$(dirname "${ENV_FILE}")"
if [[ ! -f "${ENV_FILE}" ]]; then
    cat > "${ENV_FILE}" <<'EOF'
# Subterra WG hub setup configuration.
# Fill in the blanks and re-run setup.sh.

# IPv4 address of the Zabbix server on the datacenter LAN.
# Schools reach this and only this through the tunnel.
ZABBIX_IP=

# CIDR allowed to SSH into the concentrator from the management network.
# Example: 203.0.113.0/24
MGMT_CIDR=

# Public endpoint Pis will dial. host:port form.
# Example: hub.example.com:51820
WG_ENDPOINT=
EOF
    chmod 600 "${ENV_FILE}"
    echo "wrote template ${ENV_FILE}; edit it and re-run setup.sh" >&2
    exit 2
fi

# shellcheck source=/dev/null
source "${ENV_FILE}"
for var in ZABBIX_IP MGMT_CIDR WG_ENDPOINT; do
    if [[ -z "${!var:-}" ]]; then
        echo "missing ${var} in ${ENV_FILE}" >&2
        exit 2
    fi
done

echo "[1/8] installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    wireguard wireguard-tools iptables iptables-persistent \
    python3-venv python3-pip unattended-upgrades ca-certificates rsync

echo "[2/8] creating service user and directories"
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd --system --home-dir "${STATE_DIR}" --shell /usr/sbin/nologin "${SERVICE_USER}"
fi
install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0750 "${STATE_DIR}"
install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0750 "${WG_DIR}"
install -d -o root -g root -m 0755 "${INSTALL_DIR}"

echo "[3/8] syncing source"
rsync -a --delete \
    --exclude='.git/' --exclude='.venv/' --exclude='__pycache__/' \
    --exclude='tests/' --exclude='*.db*' \
    "${REPO_ROOT}/" "${INSTALL_DIR}/"
chown -R root:root "${INSTALL_DIR}"

echo "[4/8] building venv"
if [[ ! -d "${INSTALL_DIR}/.venv" ]]; then
    python3 -m venv "${INSTALL_DIR}/.venv"
fi
"${INSTALL_DIR}/.venv/bin/pip" install -q -U pip
"${INSTALL_DIR}/.venv/bin/pip" install -q -e "${INSTALL_DIR}"

echo "[5/8] bootstrapping hub keys and wg0.conf"
SUBTERRA_DB="${STATE_DIR}/state.db" \
    SUBTERRA_WG_CONF="${WG_DIR}/wg0.conf" \
    SUBTERRA_HUB_PRIVKEY="${WG_DIR}/hub.key" \
    SUBTERRA_HUB_PUBKEY="${WG_DIR}/hub.pubkey" \
    "${INSTALL_DIR}/.venv/bin/subterra-hub" bootstrap
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${WG_DIR}" "${STATE_DIR}"
chmod 0600 "${WG_DIR}/hub.key" "${WG_DIR}/wg0.conf"
chmod 0644 "${WG_DIR}/hub.pubkey"

echo "[6/8] installing firewall + sysctl"
install -o root -g root -m 0644 "${REPO_ROOT}/firewall/sysctl.conf" \
    /etc/sysctl.d/99-subterra-hub.conf
sysctl --system >/dev/null

mkdir -p /etc/iptables
sed -e "s|__ZABBIX_IP__|${ZABBIX_IP}|g" \
    -e "s|__MGMT_CIDR__|${MGMT_CIDR}|g" \
    "${REPO_ROOT}/firewall/iptables.rules" > /etc/iptables/rules.v4
chmod 0600 /etc/iptables/rules.v4
iptables-restore < /etc/iptables/rules.v4

echo "[7/8] installing systemd units"
install -o root -g root -m 0644 "${REPO_ROOT}/systemd/enrollment.service" \
    /etc/systemd/system/enrollment.service
install -d -o root -g root -m 0755 /etc/systemd/system/wg-quick@wg0.service.d
install -o root -g root -m 0644 \
    "${REPO_ROOT}/systemd/wg-quick@wg0.service.d/override.conf" \
    /etc/systemd/system/wg-quick@wg0.service.d/override.conf
systemctl daemon-reload

echo "[8/8] starting services"
systemctl enable --now wg-quick@wg0.service
systemctl enable --now enrollment.service
systemctl enable --now netfilter-persistent.service

echo
echo "Concentrator ready. Hub public key:"
cat "${WG_DIR}/hub.pubkey"
echo
echo "WG endpoint (configure DNS / NAT to match): ${WG_ENDPOINT}"
echo "Next: add a school and issue an enrollment token:"
echo "  sudo -u ${SERVICE_USER} ${INSTALL_DIR}/.venv/bin/subterra-hub add-school <slug> '<Display Name>'"
echo "  sudo -u ${SERVICE_USER} ${INSTALL_DIR}/.venv/bin/subterra-hub issue-token <slug>"
