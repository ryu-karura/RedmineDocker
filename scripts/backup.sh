#!/bin/bash
# scripts/backup.sh
#
# Automated backup script for the redmine Redmine stack.
# Retains exactly 7 generations of backups.
#
# Backup scope:
#   - PostgreSQL database: redmine (pg_dump custom format)
#   - Uploaded files:      /opt/redmine/data/redmine/files/ (tar+gzip)
#
# Backup destinations:
#   - DB dumps:      /opt/redmine/backup/db/
#   - File archives: /opt/redmine/backup/files/
#
# Runs rootless as the `redmine` user (no sudo — it drives rootless Podman).
# Cron installation (daily at 02:00) via the redmine user's crontab (`crontab -e`):
#   0 2 * * * /opt/redmine/containers/scripts/backup.sh >> /opt/redmine/backup/backup.log 2>&1
#
# Reads /opt/redmine/containers/.env (DATA_ROOT, DB_NAME, DB_USER,
# DB_CONTAINER_NAME), if present, for the same non-secret values the Quadlet
# units use — see docs/Design.md, "設定項目" for why Quadlet unit files
# themselves cannot read this file. Every value below defaults to the
# stack's standard layout, so this script behaves exactly as before when no
# .env exists.

set -euo pipefail

# ── Load non-secret overrides from .env, if present ───────────────────────────
ENV_FILE="${ENV_FILE:-/opt/redmine/containers/.env}"
if [ -r "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi

# ── Configuration ──────────────────────────────────────────────────────────────
DATA_ROOT="${DATA_ROOT:-/opt/redmine}"
SECRETS_DIR="${SECRETS_DIR:-${DATA_ROOT}/containers/secrets}"
DB_PASSWORD_FILE="${DB_PASSWORD_FILE:-${SECRETS_DIR}/db_password.txt}"
BACKUP_DB_DIR="${DATA_ROOT}/backup/db"
BACKUP_FILES_DIR="${DATA_ROOT}/backup/files"
FILES_SOURCE_DIR="${DATA_ROOT}/data/redmine/files"
DB_CONTAINER="${DB_CONTAINER_NAME:-redmine-db}"
DB_NAME="${DB_NAME:-redmine}"
DB_USER="${DB_USER:-redmine}"
KEEP_GENERATIONS=7
TIMESTAMP=$(date -u '+%Y%m%d_%H%M%S')
LOG_PREFIX="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [backup]"

# ── Helper functions ───────────────────────────────────────────────────────────
log()  { echo "${LOG_PREFIX} $*"; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }
warn() { echo "${LOG_PREFIX} WARNING: $*" >&2; }

# ── Load the database password (Podman/Docker secret file) ────────────────────
[ -r "${DB_PASSWORD_FILE}" ] || die "DB password file not readable: ${DB_PASSWORD_FILE}"
DB_PASSWORD="$(cat "${DB_PASSWORD_FILE}")"
[ -n "${DB_PASSWORD}" ] || die "DB password file is empty: ${DB_PASSWORD_FILE}"

# ── Verify the database container is running ──────────────────────────────────
if ! podman container inspect "${DB_CONTAINER}" --format '{{.State.Status}}' 2>/dev/null | grep -q 'running'; then
    die "Container '${DB_CONTAINER}' is not running. Cannot perform backup."
fi

# ── Create backup directories if needed ───────────────────────────────────────
mkdir -p "${BACKUP_DB_DIR}" "${BACKUP_FILES_DIR}"
chmod 750 "${BACKUP_DB_DIR}" "${BACKUP_FILES_DIR}"

log "Starting backup (timestamp: ${TIMESTAMP}) ..."

# ── Function: backup the database ─────────────────────────────────────────────
backup_database() {
    local OUTFILE="${BACKUP_DB_DIR}/${DB_NAME}_${TIMESTAMP}.dump"

    log "Backing up database: ${DB_NAME} → $(basename "${OUTFILE}")"

    podman exec -e PGPASSWORD="${DB_PASSWORD}" "${DB_CONTAINER}" \
        pg_dump -U "${DB_USER}" -F c -Z 6 "${DB_NAME}" > "${OUTFILE}"

    local SIZE
    SIZE=$(du -sh "${OUTFILE}" | cut -f1)
    log "  Database backup complete: ${SIZE}"

    # ── Rotate: keep only KEEP_GENERATIONS most recent backups ───────────────
    local COUNT
    COUNT=$(find "${BACKUP_DB_DIR}" -maxdepth 1 -type f -regex ".*/${DB_NAME}_[0-9]{8}_[0-9]{6}\.dump" 2>/dev/null | wc -l)
    if [ "${COUNT}" -gt "${KEEP_GENERATIONS}" ]; then
        log "  Rotating old backups (keeping ${KEEP_GENERATIONS}, found ${COUNT}) ..."
        find "${BACKUP_DB_DIR}" -maxdepth 1 -type f -regex ".*/${DB_NAME}_[0-9]{8}_[0-9]{6}\.dump" -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr \
            | cut -d' ' -f2- \
            | tail -n +"$((KEEP_GENERATIONS + 1))" \
            | xargs rm -f
        log "  Rotation complete."
    fi
}

# ── Function: backup uploaded files ───────────────────────────────────────────
backup_files() {
    local OUTFILE="${BACKUP_FILES_DIR}/redmine_${TIMESTAMP}.tar.gz"

    if [ ! -d "${FILES_SOURCE_DIR}" ]; then
        warn "Files directory not found: ${FILES_SOURCE_DIR}. Skipping."
        return 0
    fi

    log "Backing up files: ${FILES_SOURCE_DIR} → $(basename "${OUTFILE}")"

    tar --create --gzip \
        --file="${OUTFILE}" \
        --directory="$(dirname "${FILES_SOURCE_DIR}")" \
        "$(basename "${FILES_SOURCE_DIR}")"

    local SIZE
    SIZE=$(du -sh "${OUTFILE}" | cut -f1)
    log "  Files backup complete: ${SIZE}"

    # ── Rotate ───────────────────────────────────────────────────────────────
    local COUNT
    COUNT=$(find "${BACKUP_FILES_DIR}" -maxdepth 1 -type f -regex ".*/redmine_[0-9]{8}_[0-9]{6}\.tar\.gz" 2>/dev/null | wc -l)
    if [ "${COUNT}" -gt "${KEEP_GENERATIONS}" ]; then
        log "  Rotating old file backups (keeping ${KEEP_GENERATIONS}, found ${COUNT}) ..."
        find "${BACKUP_FILES_DIR}" -maxdepth 1 -type f -regex ".*/redmine_[0-9]{8}_[0-9]{6}\.tar\.gz" -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr \
            | cut -d' ' -f2- \
            | tail -n +"$((KEEP_GENERATIONS + 1))" \
            | xargs rm -f
        log "  Rotation complete."
    fi
}

# ── Perform backups ────────────────────────────────────────────────────────────
backup_database
backup_files

# ── Summary ───────────────────────────────────────────────────────────────────
log "Backup complete."
log "DB backups:   $(find "${BACKUP_DB_DIR}" -maxdepth 1 -type f -regex ".*/.*\.dump" 2>/dev/null | wc -l) files in ${BACKUP_DB_DIR}"
log "File backups: $(find "${BACKUP_FILES_DIR}" -maxdepth 1 -type f -regex ".*/.*\.tar\.gz" 2>/dev/null | wc -l) files in ${BACKUP_FILES_DIR}"
