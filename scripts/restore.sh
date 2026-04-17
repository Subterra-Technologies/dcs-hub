#!/usr/bin/env bash
# Restore a Headscale coordinator from a backup directory created by
# scripts/backup.sh.
#
# Usage:
#   sudo ./restore.sh <backup-dir>
#
# This will:
#   1. Stop headscale.service if running.
#   2. Refuse if /var/lib/headscale/db.sqlite exists and no --force given.
#   3. Restore db.sqlite, noise_private.key, config.yaml, acl.hujson.
#   4. Fix ownership.
#   5. Start headscale.service.
#   6. Run a sanity check (`headscale users list`).
set -euo pipefail

SKIP_SYSTEMCTL="${SUBTERRA_SKIP_SYSTEMCTL:-0}"
if [[ $EUID -ne 0 && "${SKIP_SYSTEMCTL}" != "1" ]]; then
    echo "restore.sh must run as root (or set SUBTERRA_SKIP_SYSTEMCTL=1 for test)" >&2
    exit 1
fi

FORCE=0
if [[ "${1:-}" = "--force" ]]; then
    FORCE=1
    shift
fi

BACKUP_DIR="${1:?backup directory path required}"
[[ -d "${BACKUP_DIR}" ]] || { echo "no such directory: ${BACKUP_DIR}" >&2; exit 2; }

HEADSCALE_STATE="${SUBTERRA_HEADSCALE_STATE:-/var/lib/headscale}"
HEADSCALE_ETC="${SUBTERRA_HEADSCALE_ETC:-/etc/headscale}"
HEADSCALE_USER="${SUBTERRA_HEADSCALE_USER:-headscale}"

if [[ -f "${HEADSCALE_STATE}/db.sqlite" && ${FORCE} -ne 1 ]]; then
    echo "existing db at ${HEADSCALE_STATE}/db.sqlite — refusing to clobber." >&2
    echo "Move it aside or pass --force." >&2
    exit 3
fi

echo "[1/4] stopping headscale"
if [[ "${SKIP_SYSTEMCTL}" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl stop headscale.service 2>/dev/null || true
fi

echo "[2/4] restoring files from ${BACKUP_DIR}"
install -d -m 0750 "${HEADSCALE_STATE}"
install -d -m 0755 "${HEADSCALE_ETC}"

if [[ -f "${BACKUP_DIR}/db.sql.gz" ]]; then
    tmp="$(mktemp)"
    trap 'rm -f "${tmp}"' EXIT
    gunzip -c "${BACKUP_DIR}/db.sql.gz" > "${tmp}"
    rm -f "${HEADSCALE_STATE}/db.sqlite" "${HEADSCALE_STATE}/db.sqlite-journal" \
          "${HEADSCALE_STATE}/db.sqlite-wal" "${HEADSCALE_STATE}/db.sqlite-shm"
    sqlite3 "${HEADSCALE_STATE}/db.sqlite" < "${tmp}"
fi

if [[ -f "${BACKUP_DIR}/noise_private.key" ]]; then
    install -m 0600 "${BACKUP_DIR}/noise_private.key" \
        "${HEADSCALE_STATE}/noise_private.key"
fi
for f in config.yaml acl.hujson; do
    [[ -f "${BACKUP_DIR}/${f}" ]] && install -m 0644 "${BACKUP_DIR}/${f}" \
        "${HEADSCALE_ETC}/${f}"
done

echo "[3/4] fixing ownership"
if [[ $EUID -eq 0 ]] && id -u "${HEADSCALE_USER}" >/dev/null 2>&1; then
    chown -R "${HEADSCALE_USER}:${HEADSCALE_USER}" "${HEADSCALE_STATE}"
fi

echo "[4/4] starting headscale + verifying"
if [[ "${SKIP_SYSTEMCTL}" = "1" ]]; then
    echo "restore: files placed (systemctl skipped). Start headscale to verify."
elif command -v systemctl >/dev/null 2>&1; then
    systemctl start headscale.service
    sleep 2
    systemctl is-active --quiet headscale.service || {
        echo "headscale.service failed to start; journalctl -u headscale -e" >&2
        exit 4
    }
    headscale users list >/dev/null
    echo "restore: ok — headscale up, $(headscale users list 2>/dev/null | wc -l) rows in users list"
else
    echo "restore: files placed. Start headscale manually and verify."
fi
