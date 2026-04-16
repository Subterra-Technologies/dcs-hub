#!/usr/bin/env bash
# Read a subterra-hub show-zabbix-config output on stdin, substitute the
# local private key into the PrivateKey line, write to /etc/wireguard/wg0.conf,
# bring the interface up (or syncconf if already up).
#
# Usage:
#   sudo ./apply-config.sh < /tmp/config-from-coordinator.conf
#   OR
#   ssh coordinator 'sudo -u subterra-hub /opt/subterra-hub/.venv/bin/subterra-hub show-zabbix-config $(hostname)' | sudo ./apply-config.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "apply-config.sh must run as root (try: sudo $0)" >&2
    exit 1
fi

WG_DIR=/etc/wireguard
PRIVKEY_FILE="${WG_DIR}/privatekey"
WG_CONF="${WG_DIR}/wg0.conf"

[[ -s "${PRIVKEY_FILE}" ]] || {
    echo "no privatekey at ${PRIVKEY_FILE}; run bootstrap.sh first" >&2
    exit 2
}

INPUT="$(cat)"
if [[ -z "${INPUT}" ]]; then
    echo "empty stdin; expecting output of 'subterra-hub show-zabbix-config'" >&2
    exit 2
fi

if ! grep -q '^\[Interface\]' <<<"${INPUT}"; then
    echo "stdin does not look like a wg config (no [Interface] section)" >&2
    exit 2
fi

PRIV="$(tr -d '\n' < "${PRIVKEY_FILE}")"

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
printf '%s\n' "${INPUT}" |
    sed "s|^PrivateKey = <ZABBIX_PRIVATE_KEY>|PrivateKey = ${PRIV}|" \
    > "${TMP}"

if ! grep -q "^PrivateKey = ${PRIV}" "${TMP}"; then
    echo "failed to substitute PrivateKey; placeholder not found" >&2
    exit 3
fi

install -m 0600 -o root -g root "${TMP}" "${WG_CONF}"

if ip link show wg0 >/dev/null 2>&1; then
    echo "wg0 exists; syncing config without dropping tunnel"
    wg syncconf wg0 <(wg-quick strip wg0)
else
    echo "bringing wg0 up"
    systemctl enable --now wg-quick@wg0
fi

echo "applied ${WG_CONF}"
wg show wg0
