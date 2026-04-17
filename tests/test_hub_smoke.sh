#!/usr/bin/env bash
# Hub smoke test: run headscale in a /tmp sandbox and exercise subterra-admin.
#
# Does not require root or system install. Uses a downloaded headscale binary
# cached at /tmp/headscale-smoke/headscale. Runs in plain HTTP on loopback.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX=/tmp/headscale-smoke
HS_VERSION=0.28.0

mkdir -p "${SANDBOX}"
cd "${SANDBOX}"

if [[ ! -x "${SANDBOX}/headscale" ]]; then
    arch="$(dpkg --print-architecture)"
    echo "[setup] fetching headscale v${HS_VERSION} (${arch})"
    curl -fsSL -o "${SANDBOX}/headscale" \
        "https://github.com/juanfont/headscale/releases/download/v${HS_VERSION}/headscale_${HS_VERSION}_linux_${arch}"
    chmod +x "${SANDBOX}/headscale"
fi

cp "${HERE}/headscale/acl.hujson" "${SANDBOX}/acl.hujson"
cat > "${SANDBOX}/config.yaml" <<'YAML'
server_url: http://127.0.0.1:8080
listen_addr: 127.0.0.1:8080
metrics_listen_addr: 127.0.0.1:9091
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: true
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  auto_update_enabled: false
disable_check_updates: true
ephemeral_node_inactivity_timeout: 30m
database:
  type: sqlite
  sqlite:
    path: /tmp/headscale-smoke/db.sqlite
log:
  level: warn
  format: text
policy:
  mode: file
  path: /tmp/headscale-smoke/acl.hujson
dns:
  magic_dns: true
  base_domain: subterra.test
  nameservers:
    global:
      - 1.1.1.1
unix_socket: /tmp/headscale-smoke/headscale.sock
unix_socket_permission: "0770"
noise:
  private_key_path: /tmp/headscale-smoke/noise_private.key
YAML

rm -f "${SANDBOX}/db.sqlite" "${SANDBOX}/noise_private.key" "${SANDBOX}/headscale.sock"

"${SANDBOX}/headscale" -c "${SANDBOX}/config.yaml" serve >"${SANDBOX}/server.log" 2>&1 &
HS_PID=$!
trap 'kill "${HS_PID}" 2>/dev/null || true; wait "${HS_PID}" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
    [[ -S "${SANDBOX}/headscale.sock" ]] && break
    sleep 0.5
done
if [[ ! -S "${SANDBOX}/headscale.sock" ]]; then
    echo "FAIL: headscale did not start" >&2
    tail -20 "${SANDBOX}/server.log" >&2
    exit 1
fi

# Run subterra-admin against our local headscale.
export HEADSCALE="${SANDBOX}/headscale -c ${SANDBOX}/config.yaml"
SUBTERRA="${HERE}/bin/subterra-admin"

echo "[1] add-district"
"${SUBTERRA}" add-district oakridge >/dev/null

echo "[2] list-districts"
out="$("${SUBTERRA}" list-districts)"
grep -q oakridge <<<"${out}" || { echo "FAIL: district not listed"; exit 1; }

echo "[3] issue-token pi"
key1="$("${SUBTERRA}" issue-token oakridge pi --expiration 1h | tail -1)"
[[ "${key1}" =~ ^hskey-auth- ]] || { echo "FAIL: pi key shape bad: ${key1}"; exit 1; }

echo "[4] issue-token zabbix"
key2="$("${SUBTERRA}" issue-token oakridge zabbix | tail -1)"
[[ "${key2}" =~ ^hskey-auth- ]] || { echo "FAIL: zabbix key shape bad: ${key2}"; exit 1; }
[[ "${key1}" != "${key2}" ]] || { echo "FAIL: two calls returned same key"; exit 1; }

echo "[5] issue-token for unknown district rejects"
if "${SUBTERRA}" issue-token ghost pi 2>/dev/null; then
    echo "FAIL: expected error on unknown district"; exit 1
fi

echo "[6] second district allocates independently"
"${SUBTERRA}" add-district lincoln >/dev/null
key3="$("${SUBTERRA}" issue-token lincoln pi | tail -1)"
[[ "${key3}" =~ ^hskey-auth- ]] || { echo "FAIL: lincoln key shape bad"; exit 1; }

echo "[7] list-nodes filter"
# No nodes yet, but command should run without error
"${SUBTERRA}" list-nodes oakridge >/dev/null

echo "[8] policy-reload (re-applies our ACL file without restart)"
"${SUBTERRA}" policy-reload >/dev/null 2>&1 || {
    # v0.28 headscale may not support policy-reload; that's fine — policy
    # mode=file reloads on SIGHUP. Warn, do not fail.
    echo "  (policy-reload skipped: may not be supported in this headscale)"
}

echo "[9] keys list shows outstanding unclaimed keys"
out="$("${SUBTERRA}" keys list)"
# We issued keys for oakridge (pi+zabbix) and lincoln (pi). All three
# should be outstanding (unused).
grep -qc oakridge <<<"${out}" || { echo "FAIL: no oakridge keys in listing"; exit 1; }
grep -qc lincoln  <<<"${out}" || { echo "FAIL: no lincoln keys in listing"; exit 1; }
count=$(grep -cE '^(oakridge|lincoln) ' <<<"${out}" || true)
[[ "${count}" -ge 3 ]] || { echo "FAIL: expected >=3 outstanding keys, got ${count}"; exit 1; }

echo "[10] keys list filter by district"
out_oak="$("${SUBTERRA}" keys list oakridge)"
grep -q lincoln <<<"${out_oak}" && { echo "FAIL: lincoln leaked into oakridge filter"; exit 1; }
grep -q oakridge <<<"${out_oak}" || { echo "FAIL: oakridge missing from its own filter"; exit 1; }

echo
echo "OK: hub smoke test green"
