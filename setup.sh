#!/usr/bin/env bash
# Provision a fresh Debian 12+ VM as the Subterra Headscale coordinator.
#
# Installs Headscale + cloudflared + the fleet dashboard + backup and
# cert-check timers. Idempotent; safe to re-run.
#
# Prereqs BEFORE running:
#   1. A Cloudflare Tunnel created in Zero Trust → Networks → Tunnels,
#      with its Public Hostname tab mapping <COORDINATOR_HOSTNAME> to
#      `HTTP localhost:8080`. Copy the install token.
#   2. This VM has outbound HTTPS to the internet (for cloudflared).
#   3. No inbound ports required — cloudflared dials OUT. Only MGMT_CIDR
#      reaches the VM directly (SSH, dashboard).
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

# Public hostname for the Headscale server. Point this at your Cloudflare
# Tunnel's public hostname (e.g. hub.subterra.one). Cloudflare handles TLS.
COORDINATOR_HOSTNAME=

# Cloudflare Tunnel token. Create a tunnel in Cloudflare Zero Trust
# (Networks -> Tunnels -> Create tunnel -> Cloudflared), paste the token
# here. In the Public Hostnames tab of that tunnel, add:
#   Subdomain: <hub>        Domain: <yourdomain>
#   Service:   HTTP          URL: localhost:8080
CLOUDFLARE_TUNNEL_TOKEN=

# Ops email(s) that should have group:ops access (comma-separated).
# Written into headscale/acl.hujson at install time.
OPS_EMAIL=

# CIDR allowed to SSH into the coordinator + access the LAN-only
# dashboard at :8081. Typically your DC management network.
# Example: 10.10.0.0/24
MGMT_CIDR=
EOF
    chmod 600 "${ENV_FILE}"
    echo "wrote template ${ENV_FILE}; fill it in and re-run" >&2
    exit 2
fi

# shellcheck source=/dev/null
source "${ENV_FILE}"
for var in COORDINATOR_HOSTNAME CLOUDFLARE_TUNNEL_TOKEN OPS_EMAIL MGMT_CIDR; do
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

if ! command -v cloudflared >/dev/null 2>&1; then
    echo "installing cloudflared from Cloudflare's apt repo"
    # Pick the apt suite matching this distro. Cloudflare publishes for
    # bookworm, bullseye, buster (Debian) and jammy, noble, focal (Ubuntu).
    # Read VERSION_CODENAME from /etc/os-release; fall back to bookworm
    # since Cloudflare's .debs are broadly forward-compatible.
    # shellcheck source=/dev/null
    . /etc/os-release
    CF_SUITE="${VERSION_CODENAME:-bookworm}"
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        > /usr/share/keyrings/cloudflare-main.gpg
    cat > /etc/apt/sources.list.d/cloudflared.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared ${CF_SUITE} main
EOF
    apt-get update -qq || true
    if ! apt-get install -y -qq cloudflared 2>/dev/null; then
        echo "cloudflared install failed for suite '${CF_SUITE}'; falling back to bookworm"
        sed -i "s| ${CF_SUITE} main| bookworm main|" /etc/apt/sources.list.d/cloudflared.list
        apt-get update -qq
        apt-get install -y -qq cloudflared
    fi
fi

echo "[2/5] writing config + ACL"
install -d -o root -g root -m 0755 /etc/headscale
sed \
    -e "s|{{HOSTNAME}}|${COORDINATOR_HOSTNAME}|g" \
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
# Headscale daemon runs as the `headscale` user (created by the .deb).
# Its state dir must be owned by that user or the noise key write fails.
if id -u headscale >/dev/null 2>&1; then
    chown -R headscale:headscale /var/lib/headscale
fi

echo "[3/5] installing subterra-admin wrapper + helpers"
install -o root -g root -m 0755 "${REPO_ROOT}/bin/subterra-admin" \
    /usr/local/bin/subterra-admin
install -o root -g root -m 0755 "${REPO_ROOT}/scripts/cert-check.sh" \
    /usr/local/bin/subterra-cert-check
install -o root -g root -m 0755 "${REPO_ROOT}/scripts/backup.sh" \
    /usr/local/bin/subterra-backup
install -o root -g root -m 0755 "${REPO_ROOT}/scripts/restore.sh" \
    /usr/local/bin/subterra-restore

echo "[4/5] firewall + dashboard install"
mkdir -p /etc/iptables
sed "s|__MGMT_CIDR__|${MGMT_CIDR}|g" \
    "${REPO_ROOT}/firewall/iptables.rules" > /etc/iptables/rules.v4
chmod 0600 /etc/iptables/rules.v4
iptables-restore < /etc/iptables/rules.v4

install -d -o root -g root -m 0755 /usr/local/lib/subterra-dashboard
install -o root -g root -m 0644 "${REPO_ROOT}/dashboard/app.py" \
    /usr/local/lib/subterra-dashboard/app.py

# App-level allowlist matching the iptables MGMT_CIDR rule (defense in depth).
install -d -o root -g root -m 0755 /etc/systemd/system/subterra-dashboard.service.d
cat > /etc/systemd/system/subterra-dashboard.service.d/allow-cidr.conf <<EOF
[Service]
Environment=SUBTERRA_DASHBOARD_ALLOW_CIDRS=${MGMT_CIDR},127.0.0.0/8
EOF

echo "[5/5] starting headscale + cloudflared + dashboard + timers"
for unit in subterra-cert-check.service subterra-cert-check.timer \
            subterra-backup.service subterra-backup.timer \
            subterra-dashboard.service; do
    install -o root -g root -m 0644 "${REPO_ROOT}/systemd/${unit}" \
        "/etc/systemd/system/${unit}"
done
install -d -o root -g root -m 0700 /var/backups/subterra-hub
systemctl daemon-reload
systemctl enable --now headscale.service
systemctl enable --now netfilter-persistent.service
systemctl enable --now subterra-cert-check.timer
systemctl enable --now subterra-backup.timer
systemctl enable --now subterra-dashboard.service

# cloudflared ships its own `service install <TOKEN>` that writes and
# starts the systemd unit. Re-install (idempotent) so token changes apply.
if systemctl is-active --quiet cloudflared.service; then
    echo "cloudflared already running; uninstalling old service before re-install"
    cloudflared service uninstall 2>/dev/null || true
fi
cloudflared service install "${CLOUDFLARE_TUNNEL_TOKEN}"

sleep 3
if systemctl is-active --quiet headscale.service; then
    echo
    echo "Coordinator up at https://${COORDINATOR_HOSTNAME}"
    echo "Next: sudo subterra-admin add-district <slug>"
else
    echo "headscale.service failed to start; journalctl -u headscale -e" >&2
    exit 3
fi
