#!/usr/bin/env bash
# Provision a fresh Debian 12+ VM as the Subterra Headscale coordinator.
#
# Installs headscale + configures for built-in Let's Encrypt TLS + writes
# ACL policy + enables the service. Idempotent; safe to re-run.
#
# Requires, BEFORE running:
#   1. DNS A record: <COORDINATOR_HOSTNAME> -> this VM's public IP.
#   2. Edge router port-forwards: TCP/80 + TCP/443 -> this VM.
#   3. This VM has public reachability for the Let's Encrypt HTTP-01 challenge.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "setup.sh must run as root (try: sudo $0)" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE=/etc/subterra-hub/setup.env
HEADSCALE_VERSION="${HEADSCALE_VERSION:-0.28.0}"

mkdir -p "$(dirname "${ENV_FILE}")"
if [[ ! -f "${ENV_FILE}" ]]; then
    cat > "${ENV_FILE}" <<'EOF'
# Subterra Headscale coordinator config.
# Fill these in and re-run setup.sh.

# Public hostname for the Headscale server. Must resolve to this VM.
# Nodes will register against https://<this>.
COORDINATOR_HOSTNAME=

# Email for Let's Encrypt registration + cert renewal notices.
ACME_EMAIL=

# Ops email(s) that should have group:ops access (comma-separated).
# Written into headscale/acl.hujson at install time.
OPS_EMAIL=
EOF
    chmod 600 "${ENV_FILE}"
    echo "wrote template ${ENV_FILE}; fill it in and re-run" >&2
    exit 2
fi

# shellcheck source=/dev/null
source "${ENV_FILE}"
for var in COORDINATOR_HOSTNAME ACME_EMAIL OPS_EMAIL; do
    if [[ -z "${!var:-}" ]]; then
        echo "missing ${var} in ${ENV_FILE}" >&2
        exit 2
    fi
done

ARCH="$(dpkg --print-architecture)"
case "${ARCH}" in
    amd64|arm64) ;;
    *) echo "unsupported arch: ${ARCH}"; exit 2 ;;
esac
HEADSCALE_DEB_URL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_${ARCH}.deb"

echo "[1/5] installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    curl ca-certificates jq sqlite3 openssl iptables iptables-persistent \
    unattended-upgrades rsync

if ! command -v headscale >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    echo "downloading ${HEADSCALE_DEB_URL}"
    curl -fsSL -o "${tmp}/headscale.deb" "${HEADSCALE_DEB_URL}"
    dpkg -i "${tmp}/headscale.deb"
    rm -rf "${tmp}"
fi

echo "[2/5] writing config + ACL"
install -d -o root -g root -m 0755 /etc/headscale
sed \
    -e "s|{{HOSTNAME}}|${COORDINATOR_HOSTNAME}|g" \
    -e "s|{{ACME_EMAIL}}|${ACME_EMAIL}|g" \
    "${REPO_ROOT}/headscale/config.yaml" > /etc/headscale/config.yaml

# Rewrite acl.hujson so group:ops contains the configured OPS_EMAIL(s).
# Split comma-separated list to JSON array form.
ops_array="$(
    IFS=',' read -ra emails <<< "${OPS_EMAIL}"
    first=1
    for e in "${emails[@]}"; do
        e_trim="$(echo "$e" | xargs)"
        [[ -z "${e_trim}" ]] && continue
        if [[ ${first} -eq 1 ]]; then
            printf '"%s"' "${e_trim}"
            first=0
        else
            printf ', "%s"' "${e_trim}"
        fi
    done
)"
sed "s|\"noah@subterratechnologies\\.com\"|${ops_array}|" \
    "${REPO_ROOT}/headscale/acl.hujson" > /etc/headscale/acl.hujson

install -d -o root -g root -m 0755 /var/lib/headscale
install -d -o root -g root -m 0755 /var/lib/headscale/cache
install -d -o root -g root -m 0755 /var/run/headscale

echo "[3/5] installing subterra-admin wrapper + helpers"
install -o root -g root -m 0755 "${REPO_ROOT}/bin/subterra-admin" \
    /usr/local/bin/subterra-admin
install -o root -g root -m 0755 "${REPO_ROOT}/scripts/cert-check.sh" \
    /usr/local/bin/subterra-cert-check
install -o root -g root -m 0755 "${REPO_ROOT}/scripts/backup.sh" \
    /usr/local/bin/subterra-backup
install -o root -g root -m 0755 "${REPO_ROOT}/scripts/restore.sh" \
    /usr/local/bin/subterra-restore

echo "[4/5] firewall"
mkdir -p /etc/iptables
cat > /etc/iptables/rules.v4 <<'EOF'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -m conntrack --ctstate INVALID -j DROP

# Headscale needs public inbound on 80 (ACME HTTP-01) + 443 (API/DERP).
-A INPUT -p tcp --dport 80  -j ACCEPT
-A INPUT -p tcp --dport 443 -j ACCEPT

-A INPUT -p tcp --dport 22 -j ACCEPT
-A INPUT -p icmp -j ACCEPT

COMMIT
EOF
chmod 0600 /etc/iptables/rules.v4
iptables-restore < /etc/iptables/rules.v4

echo "[5/5] starting headscale + timers"
for unit in subterra-cert-check.service subterra-cert-check.timer \
            subterra-backup.service subterra-backup.timer; do
    install -o root -g root -m 0644 "${REPO_ROOT}/systemd/${unit}" \
        "/etc/systemd/system/${unit}"
done
install -d -o root -g root -m 0700 /var/backups/subterra-hub
systemctl daemon-reload
systemctl enable --now headscale.service
systemctl enable --now netfilter-persistent.service
systemctl enable --now subterra-cert-check.timer
systemctl enable --now subterra-backup.timer

sleep 3
if systemctl is-active --quiet headscale.service; then
    echo
    echo "Coordinator up at https://${COORDINATOR_HOSTNAME}"
    echo "Next: sudo subterra-admin add-district <slug>"
else
    echo "headscale.service failed to start; journalctl -u headscale -e" >&2
    exit 3
fi
