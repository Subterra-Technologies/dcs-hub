#!/usr/bin/env bash
# Dashboard smoke: run headscale + the dashboard in /tmp, seed some state,
# hit / and /api/status, verify content.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX=/tmp/subterra-dashboard-test
HS_VERSION=0.28.0

rm -rf "${SANDBOX}"
mkdir -p "${SANDBOX}"/{state,etc}

if [[ ! -x /tmp/headscale-smoke/headscale ]]; then
    arch="$(dpkg --print-architecture)"
    mkdir -p /tmp/headscale-smoke
    curl -fsSL -o /tmp/headscale-smoke/headscale \
        "https://github.com/juanfont/headscale/releases/download/v${HS_VERSION}/headscale_${HS_VERSION}_linux_${arch}"
    chmod +x /tmp/headscale-smoke/headscale
fi
HSBIN=/tmp/headscale-smoke/headscale

cat > "${SANDBOX}/etc/config.yaml" <<YAML
server_url: http://127.0.0.1:8083
listen_addr: 127.0.0.1:8083
metrics_listen_addr: 127.0.0.1:9093
grpc_listen_addr: 127.0.0.1:50445
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
  base_domain: subterra.test
  nameservers: {global: [1.1.1.1]}
unix_socket: ${SANDBOX}/headscale.sock
unix_socket_permission: "0770"
noise: {private_key_path: ${SANDBOX}/state/noise_private.key}
YAML
cp "${HERE}/headscale/acl.hujson" "${SANDBOX}/etc/acl.hujson"

"${HSBIN}" -c "${SANDBOX}/etc/config.yaml" serve >"${SANDBOX}/hs.log" 2>&1 &
HS_PID=$!
for _ in $(seq 1 20); do
    [[ -S "${SANDBOX}/headscale.sock" ]] && break
    sleep 0.5
done
trap 'kill ${HS_PID} ${DASH_PID:-0} 2>/dev/null || true' EXIT

HS="${HSBIN} -c ${SANDBOX}/etc/config.yaml"
${HS} users create oakridge >/dev/null
${HS} users create lincoln >/dev/null
uid=$(${HS} --output json users list | jq -r '.[] | select(.name=="oakridge") | .id')
${HS} preauthkeys create --user "${uid}" --expiration 3d --tags tag:pi >/dev/null
${HS} preauthkeys create --user "${uid}" --expiration 3d --tags tag:zabbix >/dev/null

# Find a free port
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("",0));print(s.getsockname()[1]);s.close()')"

SUBTERRA_HEADSCALE_BIN="${HSBIN}" \
SUBTERRA_HEADSCALE_CONFIG="${SANDBOX}/etc/config.yaml" \
SUBTERRA_DASHBOARD_HOST=127.0.0.1 \
SUBTERRA_DASHBOARD_PORT="${PORT}" \
SUBTERRA_DASHBOARD_CACHE_SEC=0 \
    python3 "${HERE}/dashboard/app.py" >"${SANDBOX}/dash.log" 2>&1 &
DASH_PID=$!

for _ in $(seq 1 20); do
    curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && break
    sleep 0.2
done
curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null || {
    echo "FAIL: dashboard did not start"
    cat "${SANDBOX}/dash.log"
    exit 1
}

echo "[1] /api/status returns users + keys"
api="$(curl -sf "http://127.0.0.1:${PORT}/api/status")"
echo "${api}" | jq -e '.users | length >= 2' >/dev/null || { echo "FAIL: users wrong"; exit 1; }
echo "${api}" | jq -e '.keys | length >= 2' >/dev/null  || { echo "FAIL: keys wrong"; exit 1; }

echo "[2] / returns HTML with district names + summary stats"
html="$(curl -sf "http://127.0.0.1:${PORT}/")"
grep -q oakridge <<<"${html}" || { echo "FAIL: oakridge not in HTML"; exit 1; }
grep -q lincoln  <<<"${html}" || { echo "FAIL: lincoln not in HTML"; exit 1; }
grep -q "Districts" <<<"${html}" || { echo "FAIL: header missing"; exit 1; }
grep -q "Outstanding pre-auth keys" <<<"${html}" || { echo "FAIL: keys section missing"; exit 1; }
grep -q "tag:pi" <<<"${html}" || { echo "FAIL: tag:pi not shown"; exit 1; }

echo "[3] /api/status keys count matches visible key rows"
api_keys=$(echo "${api}" | jq '[.keys[] | select((.used // false) == false)] | length')
[[ "${api_keys}" -ge 2 ]] || { echo "FAIL: expected >=2 outstanding keys, got ${api_keys}"; exit 1; }

echo "[4] 404 on unknown path"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/does-not-exist")
[[ "${code}" = "404" ]] || { echo "FAIL: unknown path returned ${code}"; exit 1; }

echo "[5] CIDR allowlist denies non-allowlisted source"
# Stop the open dashboard, start one with a non-loopback CIDR.
kill "${DASH_PID}" 2>/dev/null || true
wait "${DASH_PID}" 2>/dev/null || true
PORT2="$(python3 -c 'import socket;s=socket.socket();s.bind(("",0));print(s.getsockname()[1]);s.close()')"
SUBTERRA_HEADSCALE_BIN="${HSBIN}" \
SUBTERRA_HEADSCALE_CONFIG="${SANDBOX}/etc/config.yaml" \
SUBTERRA_DASHBOARD_HOST=127.0.0.1 \
SUBTERRA_DASHBOARD_PORT="${PORT2}" \
SUBTERRA_DASHBOARD_CACHE_SEC=0 \
SUBTERRA_DASHBOARD_ALLOW_CIDRS=203.0.113.0/24 \
    python3 "${HERE}/dashboard/app.py" >"${SANDBOX}/dash2.log" 2>&1 &
DASH_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${PORT2}/healthz" 2>/dev/null && break
    sleep 0.2
done
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT2}/")
[[ "${code}" = "403" ]] || { echo "FAIL: expected 403 for non-allowlisted, got ${code}"; exit 1; }

echo
echo "OK: dashboard smoke green (html + json + healthz + allowlist, port ${PORT})"
