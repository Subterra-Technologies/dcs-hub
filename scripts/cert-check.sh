#!/usr/bin/env bash
# Check the coordinator's public TLS cert expiry.
#
# When running behind Cloudflare Tunnel (the current default), this
# validates Cloudflare's edge cert — auto-renewed by Cloudflare, so it's
# mostly a reachability check. Does NOT detect a broken cloudflared:
# if cloudflared is down Cloudflare still serves a valid cert with a 1033
# error page. Pair with a Zabbix HTTP probe of /health for full liveness.
#
# When running with direct Let's Encrypt (no tunnel), this catches
# renewal failures before they take the fleet down.
#
# Exits:
#   0 — cert valid, > WARN_DAYS remaining
#   1 — cert valid but < WARN_DAYS remaining (systemd will mark unit failed)
#   2 — cert check failed entirely (endpoint unreachable, cert invalid)
set -euo pipefail

ENV_FILE="${DETEL_ENV_FILE:-/etc/detel-hub/setup.env}"
WARN_DAYS="${DETEL_CERT_WARN_DAYS:-14}"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

HOST="${DETEL_CERT_HOST:-${COORDINATOR_HOSTNAME:-}}"
[[ -n "${HOST}" ]] || { echo "cert-check: no hostname (DETEL_CERT_HOST or COORDINATOR_HOSTNAME)" >&2; exit 2; }

expiry_line="$(echo | openssl s_client -connect "${HOST}:443" -servername "${HOST}" \
                  -verify_return_error 2>/dev/null \
                  | openssl x509 -noout -enddate 2>/dev/null || true)"

if [[ -z "${expiry_line}" ]]; then
    echo "cert-check: FAIL could not retrieve cert for ${HOST}" >&2
    exit 2
fi

expiry_str="${expiry_line#notAfter=}"
expiry_epoch="$(date -u -d "${expiry_str}" +%s 2>/dev/null || true)"
[[ -n "${expiry_epoch}" ]] || { echo "cert-check: could not parse date '${expiry_str}'" >&2; exit 2; }

now_epoch="$(date -u +%s)"
remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

if (( remaining < 0 )); then
    echo "cert-check: FAIL cert for ${HOST} EXPIRED ${remaining#-} days ago" >&2
    exit 2
fi
if (( remaining < WARN_DAYS )); then
    echo "cert-check: WARN cert for ${HOST} expires in ${remaining} days" >&2
    exit 1
fi
echo "cert-check: ok ${HOST} expires in ${remaining} days"
exit 0
