#!/bin/bash
# scripts/restore.sh
#
# Disaster recovery restore script for RedmineDocker.
# Restores a specific Redmine environment from backup files.
#
# Usage:
#   sudo bash /opt/redmine/containers/scripts/restore.sh <env> <db_dump> <files_archive>
#
# Arguments:
#   env          — target environment: prod, test, or next
#   db_dump      — path to a .dump file created by backup.sh
#   files_archive — path to a .tar.gz file created by backup.sh
#
# Example:
#   sudo bash scripts/restore.sh prod \
#       /opt/redmine/backup/db/redmine_prod_20260620_020000.dump \
#       /opt/redmine/backup/files/redmine1_20260620_020000.tar.gz

set -euo pipefail

ENV_FILE="/opt/redmine/containers/.env"
LOG_PREFIX="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [restore]"

log()  { echo "${LOG_PREFIX} $*"; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

# ── Argument validation ────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 <env> <db_dump_file> <files_archive>"
    echo "  env: prod | test | next"
    exit 1
}

[ "$#" -eq 3 ] || usage

TARGET_ENV="$1"
DB_DUMP="$2"
FILES_ARCHIVE="$3"

# Map environment name to database and data directory
case "${TARGET_ENV}" in
    prod)
        DB_NAME="redmine_prod"
        ENV_NUM=1
        SERVICE="redmine-prod"
        ;;
    test)
        DB_NAME="redmine_test"
        ENV_NUM=2
        SERVICE="redmine-test"
        ;;
    next)
        DB_NAME="redmine_next"
        ENV_NUM=3
        SERVICE="redmine-next"
        ;;
    *)
        die "Unknown environment '${TARGET_ENV}'. Must be: prod, test, or next."
        ;;
esac

DATA_DIR="/opt/redmine/data/redmine${ENV_NUM}"
FILES_DIR="${DATA_DIR}/files"

# ── Validate inputs ───────────────────────────────────────────────────────────
[ -f "${DB_DUMP}" ]       || die "DB dump file not found: ${DB_DUMP}"
[ -f "${FILES_ARCHIVE}" ] || die "Files archive not found: ${FILES_ARCHIVE}"
[ -f "${ENV_FILE}" ]      || die "Environment file not found: ${ENV_FILE}"

# shellcheck source=/dev/null
source "${ENV_FILE}"
[ -z "${POSTGRES_SUPERUSER_PASSWORD:-}" ] && die "POSTGRES_SUPERUSER_PASSWORD not set."
[ -z "${REDMINE_DB_PASSWORD:-}" ]         && die "REDMINE_DB_PASSWORD not set."

export PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}"

# ── Safety confirmation ───────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║           REDMINE DISASTER RECOVERY RESTORE              ║"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║ Target environment:  ${TARGET_ENV} (${SERVICE})"
echo "  ║ Database:            ${DB_NAME}"
echo "  ║ DB dump:             ${DB_DUMP}"
echo "  ║ Files archive:       ${FILES_ARCHIVE}"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║ WARNING: ALL CURRENT DATA IN '${DB_NAME}' WILL BE        ║"
echo "  ║ DESTROYED AND REPLACED WITH THE BACKUP CONTENTS.         ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""
read -r -p "Type 'RESTORE' to confirm: " CONFIRM
[ "${CONFIRM}" = "RESTORE" ] || { echo "Aborted."; exit 1; }

# ── Step 1: Stop the target Redmine service ───────────────────────────────────
log "Step 1/6: Stopping ${SERVICE} ..."
if systemctl is-active --quiet "${SERVICE}" 2>/dev/null; then
    systemctl stop "${SERVICE}"
    log "  ${SERVICE} stopped."
else
    log "  ${SERVICE} was not running."
fi

# ── Step 2: Verify database container is running ──────────────────────────────
log "Step 2/6: Verifying database container ..."
podman container inspect redmine-db --format '{{.State.Status}}' 2>/dev/null | grep -q 'running' \
    || die "Container 'redmine-db' is not running."
log "  redmine-db is running."

# ── Step 3: Drop and recreate the database ────────────────────────────────────
log "Step 3/6: Recreating database ${DB_NAME} ..."
podman exec redmine-db psql -U postgres \
    -c "DROP DATABASE IF EXISTS ${DB_NAME};" || true
podman exec redmine-db psql -U postgres \
    -c "CREATE DATABASE ${DB_NAME} OWNER redmine_adm ENCODING 'UTF8' \
        LC_COLLATE 'C.UTF-8' LC_CTYPE 'C.UTF-8' TEMPLATE template0;"
podman exec redmine-db psql -U postgres -d "${DB_NAME}" \
    -c "CREATE EXTENSION IF NOT EXISTS postgis;"
podman exec redmine-db psql -U postgres -d "${DB_NAME}" \
    -c "CREATE EXTENSION IF NOT EXISTS postgis_topology;"
podman exec redmine-db psql -U postgres -d "${DB_NAME}" \
    -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO redmine_adm;"
podman exec redmine-db psql -U postgres -d "${DB_NAME}" \
    -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO redmine_adm;"
log "  Database ${DB_NAME} recreated."

# ── Step 4: Restore database from dump ────────────────────────────────────────
log "Step 4/6: Restoring database from $(basename "${DB_DUMP}") ..."
DUMP_BASENAME=$(basename "${DB_DUMP}")
podman cp "${DB_DUMP}" "redmine-db:/tmp/${DUMP_BASENAME}"
podman exec redmine-db pg_restore \
    -U postgres \
    -d "${DB_NAME}" \
    --no-owner \
    --role=redmine_adm \
    --exit-on-error \
    "/tmp/${DUMP_BASENAME}"
podman exec redmine-db rm -f "/tmp/${DUMP_BASENAME}"
log "  Database restore complete."

# ── Step 5: Restore uploaded files ────────────────────────────────────────────
log "Step 5/6: Restoring files from $(basename "${FILES_ARCHIVE}") ..."
rm -rf "${FILES_DIR:?}"/*
tar -xzf "${FILES_ARCHIVE}" -C "${DATA_DIR}/"
chown -R redmine_adm:redmine "${FILES_DIR}"
chmod -R 755 "${FILES_DIR}"
log "  Files restore complete."

# ── Step 6: Clear caches and restart ─────────────────────────────────────────
log "Step 6/6: Clearing caches and restarting ${SERVICE} ..."
rm -rf "${DATA_DIR}/tmp/cache"/*
mkdir -p "${DATA_DIR}/tmp/cache"
chown -R redmine_adm:redmine "${DATA_DIR}/tmp"

systemctl start "${SERVICE}"
log "  ${SERVICE} started."
log ""
log "Restore complete. Monitor startup:"
log "  journalctl -u ${SERVICE} -f"
