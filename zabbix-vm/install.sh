#!/usr/bin/env bash
# install.sh: one-shot installer for the Detel Zabbix-VM tools.
#
# What it does:
#   1. Installs tailscale via the upstream installer (works across distros).
#   2. Installs gum + jq (apt for Debian/Ubuntu; dnf/yum for RHEL family).
#   3. Drops detel-setup, detel, and bootstrap.sh into /usr/local/sbin.
#   4. Launches detel-setup so the operator completes enrollment immediately.
#
# Usage (on a fresh VM):
#   git clone https://github.com/Subterra-Technologies/detel-hub /tmp/hub
#   sudo bash /tmp/hub/zabbix-vm/install.sh

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
    apt-get install -y gum jq
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
    ${PKG} install -y gum jq
else
    echo "unsupported package manager — install gum and jq manually, then re-run." >&2
    exit 2
fi

echo "==> [3/4] install detel tools"
install -d -m 0755 /var/lib/detel
for script in detel-setup detel bootstrap.sh; do
    install -m 0755 "${HERE}/${script}" "/usr/local/sbin/${script}"
done

systemctl enable tailscaled.service >/dev/null 2>&1 || true

echo "==> [4/4] launching detel-setup"
echo
exec /usr/local/sbin/detel-setup
