#!/bin/bash
# scripts/restore.sh
#
# Disaster recovery restore script for the hwins Redmine stack.
#
# Usage:
#   sudo bash /opt/hwins/containers/scripts/restore.sh <db_dump> <files_archive>
#
# Arguments:
#   db_dump       — path to a .dump file created by backup.sh
#   files_archive — path to a .tar.gz file created by backup.sh
#
# Example:
#   sudo bash scripts/restore.sh \
#       /opt/hwins/backup/db/redmine_20260620_020000.dump \
#       /opt/hwins/backup/files/redmine_20260620_020000.tar.gz

set -euo pipefail

SECRETS_DIR="${SECRETS_DIR:-/opt/hwins/containers/secrets}"
DB_PASSWORD_FILE="${DB_PASSWORD_FILE:-${SECRETS_DIR}/db_password.txt}"
DB_CONTAINER="hwins-db"
DB_NAME="redmine"
DB_USER="redmine"
SERVICE="hwins-redmine"
DATA_DIR="/opt/hwins/data/redmine"
FILES_DIR="${DATA_DIR}/files"
LOG_PREFIX="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [restore]"

log()  { echo "${LOG_PREFIX} $*"; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 <db_dump_file> <files_archive>"
    exit 1
}

[ "$#" -eq 2 ] || usage
DB_DUMP="$1"
FILES_ARCHIVE="$2"

# ── Validate inputs ───────────────────────────────────────────────────────────
[ -f "${DB_DUMP}" ]          || die "DB dump file not found: ${DB_DUMP}"
[ -f "${FILES_ARCHIVE}" ]    || die "Files archive not found: ${FILES_ARCHIVE}"
[ -r "${DB_PASSWORD_FILE}" ] || die "DB password file not readable: ${DB_PASSWORD_FILE}"

DB_PASSWORD="$(cat "${DB_PASSWORD_FILE}")"
[ -n "${DB_PASSWORD}" ] || die "DB password file is empty: ${DB_PASSWORD_FILE}"

# ── Safety confirmation ───────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║           HWINS REDMINE DISASTER RECOVERY RESTORE         ║"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║ Service:   ${SERVICE}"
echo "  ║ Database:  ${DB_NAME}"
echo "  ║ DB dump:   ${DB_DUMP}"
echo "  ║ Files:     ${FILES_ARCHIVE}"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║ WARNING: ALL CURRENT DATA IN '${DB_NAME}' WILL BE         ║"
echo "  ║ DESTROYED AND REPLACED WITH THE BACKUP CONTENTS.          ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""
read -r -p "Type 'RESTORE' to confirm: " CONFIRM
[ "${CONFIRM}" = "RESTORE" ] || { echo "Aborted."; exit 1; }

# ── Step 1: Stop the Redmine service ──────────────────────────────────────────
log "Step 1/6: Stopping ${SERVICE} ..."
if systemctl is-active --quiet "${SERVICE}" 2>/dev/null; then
    systemctl stop "${SERVICE}"
    log "  ${SERVICE} stopped."
else
    log "  ${SERVICE} was not running."
fi

# ── Step 2: Verify the database container is running ──────────────────────────
log "Step 2/6: Verifying database container ..."
podman container inspect "${DB_CONTAINER}" --format '{{.State.Status}}' 2>/dev/null | grep -q 'running' \
    || die "Container '${DB_CONTAINER}' is not running."
log "  ${DB_CONTAINER} is running."

# psql/pg_restore inside the container authenticate with this password.
PSQL() { podman exec -e PGPASSWORD="${DB_PASSWORD}" "${DB_CONTAINER}" psql -U "${DB_USER}" "$@"; }

# ── Step 3: Drop and recreate the database ────────────────────────────────────
log "Step 3/6: Recreating database ${DB_NAME} ..."
PSQL -d postgres -c "DROP DATABASE IF EXISTS ${DB_NAME};" || true
PSQL -d postgres -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8' \
    LC_COLLATE 'C.UTF-8' LC_CTYPE 'C.UTF-8' TEMPLATE template0;"
PSQL -d "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS postgis;"
PSQL -d "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS postgis_topology;"
log "  Database ${DB_NAME} recreated."

# ── Step 4: Restore database from dump ────────────────────────────────────────
log "Step 4/6: Restoring database from $(basename "${DB_DUMP}") ..."
DUMP_BASENAME=$(basename "${DB_DUMP}")
podman cp "${DB_DUMP}" "${DB_CONTAINER}:/tmp/${DUMP_BASENAME}"
podman exec -e PGPASSWORD="${DB_PASSWORD}" "${DB_CONTAINER}" \
    pg_restore -U "${DB_USER}" -d "${DB_NAME}" --no-owner --role="${DB_USER}" \
        --exit-on-error "/tmp/${DUMP_BASENAME}"
podman exec "${DB_CONTAINER}" rm -f "/tmp/${DUMP_BASENAME}"
log "  Database restore complete."

# ── Step 5: Restore uploaded files ────────────────────────────────────────────
log "Step 5/6: Restoring files from $(basename "${FILES_ARCHIVE}") ..."
mkdir -p "${FILES_DIR}"
rm -rf "${FILES_DIR:?}"/*
tar -xzf "${FILES_ARCHIVE}" -C "${DATA_DIR}/"
log "  Files restore complete."

# ── Step 6: Restart the service ───────────────────────────────────────────────
log "Step 6/6: Restarting ${SERVICE} ..."
systemctl start "${SERVICE}"
log "  ${SERVICE} started."
log ""
log "Restore complete. Monitor startup:"
log "  journalctl -u ${SERVICE} -f"
