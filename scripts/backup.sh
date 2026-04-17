#!/usr/bin/env bash
# Nightly backup of the Headscale coordinator state.
#
# Writes a timestamped snapshot to BACKUP_DIR. Keeps the last RETENTION
# days of snapshots; older ones deleted. If BACKUP_REMOTE is set (ssh://
# or rsync://), also pushes there.
#
# Snapshot contents:
#   - db.sqlite  — Headscale state (districts, nodes, keys, ACL cache)
#   - noise_private.key  — server identity; losing this invalidates every node
#   - config.yaml  — server config
#   - acl.hujson  — live policy
set -euo pipefail

BACKUP_DIR="${SUBTERRA_BACKUP_DIR:-/var/backups/subterra-hub}"
RETENTION="${SUBTERRA_BACKUP_RETENTION:-14}"
HEADSCALE_STATE="${SUBTERRA_HEADSCALE_STATE:-/var/lib/headscale}"
HEADSCALE_ETC="${SUBTERRA_HEADSCALE_ETC:-/etc/headscale}"
BACKUP_REMOTE="${SUBTERRA_BACKUP_REMOTE:-}"

mkdir -p "${BACKUP_DIR}"
chmod 0700 "${BACKUP_DIR}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out_dir="${BACKUP_DIR}/${stamp}"
mkdir -p "${out_dir}"

# Use `sqlite3 .dump` rather than a raw file copy — safe against the
# headscale daemon holding a WAL handle.
if [[ -f "${HEADSCALE_STATE}/db.sqlite" ]]; then
    sqlite3 "${HEADSCALE_STATE}/db.sqlite" .dump | gzip -9 > "${out_dir}/db.sql.gz"
fi

# Noise key + config + policy are small; copy verbatim.
if [[ -f "${HEADSCALE_STATE}/noise_private.key" ]]; then
    cp -a "${HEADSCALE_STATE}/noise_private.key" "${out_dir}/noise_private.key"
fi
for f in config.yaml acl.hujson; do
    [[ -f "${HEADSCALE_ETC}/${f}" ]] && cp -a "${HEADSCALE_ETC}/${f}" "${out_dir}/${f}"
done

# Manifest — lets the restore script verify + pick a snapshot quickly.
{
    echo "timestamp: ${stamp}"
    echo "host: $(hostname -f 2>/dev/null || hostname)"
    echo "headscale_version: $(headscale version 2>/dev/null | head -1 || echo unknown)"
    echo "files:"
    (cd "${out_dir}" && find . -maxdepth 1 -mindepth 1 -printf '  - %f (%s bytes)\n')
} > "${out_dir}/manifest.txt"

chmod -R go-rwx "${out_dir}"

# Optional remote sync. If BACKUP_REMOTE is configured but the push
# fails, exit non-zero so systemd marks the backup unit failed and ops
# monitoring (Zabbix on systemd unit state) alerts — silent offsite
# failures are the worst kind.
if [[ -n "${BACKUP_REMOTE}" ]]; then
    if ! rsync -a --delete "${BACKUP_DIR}/" "${BACKUP_REMOTE%/}/"; then
        echo "backup: FAIL remote rsync to ${BACKUP_REMOTE} failed" >&2
        echo "backup: local snapshot at ${out_dir} is still good" >&2
        exit 1
    fi
fi

# Retention: delete directories older than RETENTION days.
find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION}" \
    -exec rm -rf {} +

echo "backup: ok ${out_dir}"
