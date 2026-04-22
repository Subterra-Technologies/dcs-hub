#!/usr/bin/env bash
# install.sh: one-shot installer for the DCS Zabbix-VM tools.
#
# What it does:
#   1. Installs tailscale via the upstream installer (works across distros).
#   2. Installs gum + jq (apt for Debian/Ubuntu; dnf/yum for RHEL family).
#   3. Drops dcs-setup, dcs, and bootstrap.sh into /usr/local/sbin.
#   4. Launches dcs-setup so the operator completes enrollment immediately.
#
# Usage (on a fresh VM):
#   git clone https://github.com/Subterra-Technologies/dcs-hub /tmp/hub
#   sudo bash /tmp/hub/zabbix-vm/install.sh
#
# Optional — pre-bake OAuth creds so the TUI skips the OAuth prompt:
#   export DCS_TS_OAUTH_CLIENT_ID=...
#   export DCS_TS_OAUTH_CLIENT_SECRET=...
#   sudo -E bash /tmp/hub/zabbix-vm/install.sh
# If you don't pre-bake, dcs-setup will collect the creds in-TUI on the
# first VM and persist them to /etc/dcs.conf (chmod 0600) for reuse.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "run as root (sudo)" >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [1/4] tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "==> [2/4] gum + jq"
if command -v apt-get >/dev/null 2>&1; then
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-bookworm}"
    install -d /usr/share/keyrings
    if [[ ! -f /usr/share/keyrings/charm-archive-keyring.gpg ]]; then
        curl -fsSL https://repo.charm.sh/apt/gpg.key \
            | gpg --dearmor -o /usr/share/keyrings/charm-archive-keyring.gpg
    fi
    cat > /etc/apt/sources.list.d/charm.list <<'EOF'
deb [signed-by=/usr/share/keyrings/charm-archive-keyring.gpg] https://repo.charm.sh/apt/ * *
EOF
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y gum jq git
elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    PKG=dnf; command -v dnf >/dev/null 2>&1 || PKG=yum
    cat > /etc/yum.repos.d/charm.repo <<'EOF'
[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key
EOF
    ${PKG} install -y gum jq git
else
    echo "unsupported package manager — install gum and jq manually, then re-run." >&2
    exit 2
fi

echo "==> [3/4] install dcs tools"
install -d -m 0755 /var/lib/dcs
for script in dcs-setup dcs dcs-districts dcs-mint-key dcs-query bootstrap.sh; do
    install -m 0755 "${HERE}/${script}" "/usr/local/sbin/${script}"
done

# Optional: persist OAuth creds. If skipped, dcs-setup collects them in-TUI
# on first run and writes this same file.
if [[ -n "${DCS_TS_OAUTH_CLIENT_ID:-}" && -n "${DCS_TS_OAUTH_CLIENT_SECRET:-}" ]]; then
    umask 077
    cat > /etc/dcs.conf <<EOF
# Tailscale API creds. Scopes needed (Trust credentials page):
#   devices:core    — Read, for dcs-districts and dcs-query
#   auth_keys       — Write, for dcs-mint-key (with all zabbix-* tags selected)
# Both scopes can live on one OAuth client.
DCS_TS_OAUTH_CLIENT_ID=${DCS_TS_OAUTH_CLIENT_ID}
DCS_TS_OAUTH_CLIENT_SECRET=${DCS_TS_OAUTH_CLIENT_SECRET}
DCS_TS_TAILNET=${DCS_TS_TAILNET:--}
EOF
    chmod 0600 /etc/dcs.conf
    echo "    wrote /etc/dcs.conf"
fi

# Record the source SHA so `dcs update` can show a changelog from here.
if git -C "${HERE}/.." rev-parse HEAD >/dev/null 2>&1; then
    git -C "${HERE}/.." rev-parse HEAD > /var/lib/dcs/installed-sha
fi

systemctl enable tailscaled.service >/dev/null 2>&1 || true

echo "==> [4/4] launching dcs-setup"
echo
exec /usr/local/sbin/dcs-setup
