#!/usr/bin/env bash
# Bootstrap a Zabbix VM onto the Detel tailnet (Tailscale SaaS).
#
# Prereqs:
#   - Linux VM, outbound HTTPS/UDP to the internet.
#   - Pre-auth key tagged tag:zabbix-<district> (generated in the
#     Tailscale admin console → Settings → Keys).
#
# Usage:
#   sudo bootstrap.sh \
#       --authkey tskey-auth-xxxxxxxxxxxxxxxx \
#       --hostname zabbix-oakridge-a
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "bootstrap.sh must run as root (try: sudo $0)" >&2
    exit 1
fi

AUTHKEY=""
HOSTNAME_NEW=""
ADVERTISE_ROUTES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --authkey) AUTHKEY="$2"; shift 2 ;;
        --hostname) HOSTNAME_NEW="$2"; shift 2 ;;
        --advertise-routes) ADVERTISE_ROUTES="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[[ -n "${AUTHKEY}" ]] || { echo "--authkey required" >&2; exit 2; }

echo "[1/3] installing tailscale"
export DEBIAN_FRONTEND=noninteractive
if ! command -v tailscale >/dev/null 2>&1; then
    # Tailscale's official installer auto-detects the distro
    # (Debian, Ubuntu, RHEL, CentOS, Arch, Alpine, etc.) and sets up
    # the right apt/yum/pacman repo + installs the package.
    curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "[2/3] setting hostname (if requested)"
if [[ -n "${HOSTNAME_NEW}" ]]; then
    hostnamectl set-hostname "${HOSTNAME_NEW}"
fi

echo "[3/3] joining tailnet"
args=(
    up
    --authkey "${AUTHKEY}"
    --ssh
    --accept-routes
    --accept-dns=false
    --reset
)
if [[ -n "${HOSTNAME_NEW}" ]]; then
    args+=(--hostname "${HOSTNAME_NEW}")
fi
if [[ -n "${ADVERTISE_ROUTES}" ]]; then
    args+=(--advertise-routes "${ADVERTISE_ROUTES}")
fi

tailscale "${args[@]}"

echo
echo "Joined tailnet. Status:"
tailscale status --peers=false
echo
echo "This Zabbix VM now routes district traffic via the Pi in its district."
echo "Ask the tailnet admin to verify advertised routes are approved."
