#!/usr/bin/env bash
# Bootstrap a Zabbix VM onto the Subterra tailnet.
#
# Prereqs:
#   - Debian 12+ VM, reachable out to the coordinator hostname over HTTPS 443.
#   - Pre-auth key from the coordinator:
#       subterra-admin issue-token <district> zabbix
#
# Usage:
#   sudo bootstrap.sh \
#       --coordinator https://hub.subterra.one \
#       --authkey tskey-auth-xxxxxxxxxxxxxxxx \
#       --hostname zabbix-oakridge-a \
#       [--advertise-routes 10.10.99.0/28]
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "bootstrap.sh must run as root (try: sudo $0)" >&2
    exit 1
fi

COORDINATOR=""
AUTHKEY=""
HOSTNAME_NEW=""
ADVERTISE_ROUTES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --coordinator) COORDINATOR="$2"; shift 2 ;;
        --authkey) AUTHKEY="$2"; shift 2 ;;
        --hostname) HOSTNAME_NEW="$2"; shift 2 ;;
        --advertise-routes) ADVERTISE_ROUTES="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[[ -n "${COORDINATOR}" ]] || { echo "--coordinator required" >&2; exit 2; }
[[ -n "${AUTHKEY}" ]]     || { echo "--authkey required" >&2; exit 2; }

echo "[1/3] installing tailscale"
export DEBIAN_FRONTEND=noninteractive
if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
        | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
        | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    apt-get update -qq
    apt-get install -y -qq tailscale
fi

echo "[2/3] setting hostname (if requested)"
if [[ -n "${HOSTNAME_NEW}" ]]; then
    hostnamectl set-hostname "${HOSTNAME_NEW}"
fi

echo "[3/3] joining tailnet"
args=(
    up
    --login-server "${COORDINATOR}"
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
echo "Ask the coordinator admin to approve any advertised routes with:"
echo "  subterra-admin routes <district>"
