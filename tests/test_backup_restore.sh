#!/usr/bin/env bash
# Round-trip: run headscale, create state, back it up, delete state,
# restore, start a fresh headscale instance, verify state returned.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX=/tmp/headscale-backup-test
HS_VERSION=0.28.0

rm -rf "${SANDBOX}"
mkdir -p "${SANDBOX}"/{state,etc,backups}

if [[ ! -x /tmp/headscale-smoke/headscale ]]; then
    arch="$(dpkg --print-architecture)"
    mkdir -p /tmp/headscale-smoke
    curl -fsSL -o /tmp/headscale-smoke/headscale \
        "https://github.com/juanfont/headscale/releases/download/v${HS_VERSION}/headscale_${HS_VERSION}_linux_${arch}"
    chmod +x /tmp/headscale-smoke/headscale
fi
HSBIN=/tmp/headscale-smoke/headscale

cat > "${SANDBOX}/etc/config.yaml" <<YAML
server_url: http://127.0.0.1:8082
listen_addr: 127.0.0.1:8082
metrics_listen_addr: 127.0.0.1:9092
grpc_listen_addr: 127.0.0.1:50444
grpc_allow_insecure: true
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  urls: [https://controlplane.tailscale.com/derpmap/default]
  auto_update_enabled: false
disable_check_updates: true
database:
  type: sqlite
  sqlite:
    path: ${SANDBOX}/state/db.sqlite
log: {level: warn, format: text}
policy: {mode: file, path: ${SANDBOX}/etc/acl.hujson}
dns:
  magic_dns: true
  base_domain: detel.test
  nameservers: {global: [1.1.1.1]}
unix_socket: ${SANDBOX}/headscale.sock
unix_socket_permission: "0770"
noise: {private_key_path: ${SANDBOX}/state/noise_private.key}
YAML
cp "${HERE}/headscale/acl.hujson" "${SANDBOX}/etc/acl.hujson"

start_headscale() {
    "${HSBIN}" -c "${SANDBOX}/etc/config.yaml" serve >"${SANDBOX}/server.log" 2>&1 &
    HS_PID=$!
    for _ in $(seq 1 20); do
        [[ -S "${SANDBOX}/headscale.sock" ]] && return
        sleep 0.5
    done
    echo "FAIL: headscale did not start"; tail -20 "${SANDBOX}/server.log" >&2; exit 1
}
stop_headscale() {
    kill "${HS_PID}" 2>/dev/null || true
    wait "${HS_PID}" 2>/dev/null || true
    rm -f "${SANDBOX}/headscale.sock"
}
trap 'kill ${HS_PID:-0} 2>/dev/null || true' EXIT

HS="${HSBIN} -c ${SANDBOX}/etc/config.yaml"

echo "[1] start, seed state"
start_headscale
${HS} users create oakridge >/dev/null
${HS} users create lincoln >/dev/null
uid=$(${HS} --output json users list | jq -r '.[] | select(.name=="oakridge") | .id')
${HS} preauthkeys create --user "${uid}" --expiration 3d --tags tag:pi >/dev/null
before=$(${HS} --output json users list | jq -r '.[].name' | sort | tr '\n' ',')
echo "  users before: ${before}"

echo "[2] run backup.sh"
DETEL_BACKUP_DIR="${SANDBOX}/backups" \
DETEL_BACKUP_RETENTION=7 \
DETEL_HEADSCALE_STATE="${SANDBOX}/state" \
DETEL_HEADSCALE_ETC="${SANDBOX}/etc" \
    "${HERE}/scripts/backup.sh"

snapshot="$(find "${SANDBOX}/backups" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -d "${snapshot}" ]] || { echo "FAIL: no snapshot"; exit 1; }
[[ -f "${snapshot}/db.sql.gz" ]] || { echo "FAIL: no db dump"; exit 1; }
[[ -f "${snapshot}/noise_private.key" ]] || { echo "FAIL: no noise key"; exit 1; }
[[ -f "${snapshot}/acl.hujson" ]] || { echo "FAIL: no acl"; exit 1; }
[[ -f "${snapshot}/manifest.txt" ]] || { echo "FAIL: no manifest"; exit 1; }

echo "[3] simulate disaster: stop + wipe state"
stop_headscale
rm -rf "${SANDBOX}/state"
mkdir -p "${SANDBOX}/state"

echo "[4] run restore.sh"
DETEL_SKIP_SYSTEMCTL=1 \
DETEL_HEADSCALE_STATE="${SANDBOX}/state" \
DETEL_HEADSCALE_ETC="${SANDBOX}/etc" \
    "${HERE}/scripts/restore.sh" "${snapshot%/}"

[[ -f "${SANDBOX}/state/db.sqlite" ]] || { echo "FAIL: db not restored"; exit 1; }
[[ -f "${SANDBOX}/state/noise_private.key" ]] || { echo "FAIL: noise not restored"; exit 1; }

echo "[5] start fresh headscale against restored state + verify users"
start_headscale
after=$(${HS} --output json users list | jq -r '.[].name' | sort | tr '\n' ',')
echo "  users after: ${after}"
[[ "${before}" = "${after}" ]] || { echo "FAIL: users differ before/after"; exit 1; }

keys_after=$(${HS} --output json preauthkeys list 2>/dev/null | jq 'length')
[[ "${keys_after}" -ge 1 ]] || { echo "FAIL: preauthkeys not restored (got ${keys_after})"; exit 1; }

stop_headscale
echo
echo "OK: backup/restore round-trip green"
