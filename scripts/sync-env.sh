#!/bin/bash
# scripts/sync-env.sh
#
# Synchronizes (clones) data from one Redmine environment to another.
# Used to refresh plugin test (Docker2) or upgrade test (Docker3) environments
# with current production data.
#
# Usage:
#   sudo bash /opt/redmine/containers/scripts/sync-env.sh <source> <target>
#
# Arguments:
#   source — source environment: prod
#   target — target environment: test or next
#
# Examples:
#   sudo bash scripts/sync-env.sh prod test   # Refresh Docker2 with prod data
#   sudo bash scripts/sync-env.sh prod next   # Refresh Docker3 with prod data
#
# What is synced:
#   - Database: pg_dump from source → pg_restore into target (drops and recreates)
#   - Uploaded files: rsync from source files/ to target files/ (preserves deletions)
#
# What is NOT synced:
#   - Compiled assets (public/assets/) — these are environment-specific
#   - Log files
#   - Temporary files

set -euo pipefail

ENV_FILE="/opt/redmine/containers/.env"
LOG_PREFIX="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [sync-env]"

log()  { echo "${LOG_PREFIX} $*"; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

# ── Argument validation ────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 <source> <target>"
    echo "  source: prod"
    echo "  target: test | next"
    exit 1
}

[ "$#" -eq 2 ] || usage
SOURCE_ENV="$1"
TARGET_ENV="$2"

# ── Map environment names ─────────────────────────────────────────────────────
map_env() {
    local ENV_NAME="$1"
    case "${ENV_NAME}" in
        prod) echo "redmine_prod 1 redmine-prod" ;;
        test) echo "redmine_test 2 redmine-test" ;;
        next) echo "redmine_next 3 redmine-next" ;;
        *) die "Unknown environment '${ENV_NAME}'. Must be: prod, test, or next." ;;
    esac
}

read -r SOURCE_DB SOURCE_NUM SOURCE_SERVICE <<< "$(map_env "${SOURCE_ENV}")"
read -r TARGET_DB TARGET_NUM TARGET_SERVICE <<< "$(map_env "${TARGET_ENV}")"

SOURCE_FILES="/opt/redmine/data/redmine${SOURCE_NUM}/files"
TARGET_FILES="/opt/redmine/data/redmine${TARGET_NUM}/files"
TARGET_ASSETS="/opt/redmine/data/redmine${TARGET_NUM}/public/assets"
TARGET_TMP="/opt/redmine/data/redmine${TARGET_NUM}/tmp"

[ "${SOURCE_ENV}" = "${TARGET_ENV}" ] && die "Source and target environments cannot be the same."
[ "${TARGET_ENV}" = "prod" ] && die "Production cannot be a sync target. This is a safety guard."

# ── Load environment ───────────────────────────────────────────────────────────
[ -f "${ENV_FILE}" ] || die "Environment file not found: ${ENV_FILE}"
# shellcheck source=/dev/null
source "${ENV_FILE}"
[ -z "${POSTGRES_SUPERUSER_PASSWORD:-}" ] && die "POSTGRES_SUPERUSER_PASSWORD not set."
export PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}"

# ── Safety confirmation ───────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║           ENVIRONMENT SYNCHRONIZATION                    ║"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║ Source: ${SOURCE_ENV} (${SOURCE_DB})"
echo "  ║ Target: ${TARGET_ENV} (${TARGET_DB})"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║ WARNING: ALL DATA IN '${TARGET_DB}' AND              ║"
echo "  ║ '${TARGET_FILES}' WILL BE REPLACED.              ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""
read -r -p "Type 'SYNC' to confirm: " CONFIRM
[ "${CONFIRM}" = "SYNC" ] || { echo "Aborted."; exit 1; }

# ── Verify containers ─────────────────────────────────────────────────────────
log "Verifying containers ..."
podman container inspect redmine-db --format '{{.State.Status}}' 2>/dev/null \
    | grep -q 'running' || die "'redmine-db' is not running."

# ── Step 1: Stop the target service ───────────────────────────────────────────
log "Step 1/5: Stopping ${TARGET_SERVICE} ..."
if systemctl is-active --quiet "${TARGET_SERVICE}" 2>/dev/null; then
    systemctl stop "${TARGET_SERVICE}"
    log "  ${TARGET_SERVICE} stopped."
else
    log "  ${TARGET_SERVICE} was not running."
fi

# ── Step 2: Dump the source database ──────────────────────────────────────────
SNAPSHOT_FILE="/tmp/redmine_sync_snapshot_$$.dump"
log "Step 2/5: Dumping source database '${SOURCE_DB}' ..."
PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}" \
podman exec redmine-db pg_dump \
    -U postgres \
    -F c \
    -Z 3 \
    "${SOURCE_DB}" > "${SNAPSHOT_FILE}"

DUMP_SIZE=$(du -sh "${SNAPSHOT_FILE}" | cut -f1)
log "  Dump complete: ${DUMP_SIZE}"

# ── Step 3: Restore into target database ──────────────────────────────────────
log "Step 3/5: Restoring into target database '${TARGET_DB}' ..."
podman exec redmine-db psql -U postgres \
    -c "DROP DATABASE IF EXISTS ${TARGET_DB};" || true
podman exec redmine-db psql -U postgres \
    -c "CREATE DATABASE ${TARGET_DB} OWNER redmine_adm ENCODING 'UTF8' \
        LC_COLLATE 'C.UTF-8' LC_CTYPE 'C.UTF-8' TEMPLATE template0;"
podman exec redmine-db psql -U postgres -d "${TARGET_DB}" \
    -c "CREATE EXTENSION IF NOT EXISTS postgis;"
podman exec redmine-db psql -U postgres -d "${TARGET_DB}" \
    -c "CREATE EXTENSION IF NOT EXISTS postgis_topology;"

SNAP_BASENAME=$(basename "${SNAPSHOT_FILE}")
podman cp "${SNAPSHOT_FILE}" "redmine-db:/tmp/${SNAP_BASENAME}"
podman exec redmine-db pg_restore \
    -U postgres \
    -d "${TARGET_DB}" \
    --no-owner \
    --role=redmine_adm \
    --exit-on-error \
    "/tmp/${SNAP_BASENAME}"
podman exec redmine-db rm -f "/tmp/${SNAP_BASENAME}"
rm -f "${SNAPSHOT_FILE}"
log "  Database restore complete."

# ── Step 4: Sync files ────────────────────────────────────────────────────────
log "Step 4/5: Syncing uploaded files (${SOURCE_FILES} → ${TARGET_FILES}) ..."
rsync \
    --archive \
    --delete \
    --progress \
    "${SOURCE_FILES}/" \
    "${TARGET_FILES}/"
chown -R redmine_adm:redmine "${TARGET_FILES}"
chmod -R 755 "${TARGET_FILES}"
log "  Files sync complete."

# ── Step 5: Clear assets and caches, then restart ─────────────────────────────
log "Step 5/5: Clearing compiled assets/caches and restarting ${TARGET_SERVICE} ..."
# Clear compiled assets so they are recompiled with the correct sub-URI on next start
rm -rf "${TARGET_ASSETS:?}"/*
# Clear Redmine cache
rm -rf "${TARGET_TMP:?}/cache"/*
mkdir -p "${TARGET_ASSETS}" "${TARGET_TMP}/cache"
chown -R redmine_adm:redmine \
    "${TARGET_ASSETS}" \
    "${TARGET_TMP}"

systemctl start "${TARGET_SERVICE}"
log "  ${TARGET_SERVICE} started."
log ""
log "Sync complete. Assets will be recompiled on startup."
log "  Monitor progress: journalctl -u ${TARGET_SERVICE} -f"
