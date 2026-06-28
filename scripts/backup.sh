#!/bin/bash
# scripts/backup.sh
#
# Automated backup script for RedmineDocker.
# Retains exactly 7 generations of backups.
#
# Backup scope:
#   - PostgreSQL database: redmine_prod (pg_dump custom format)
#   - Uploaded files:      /opt/redmine/data/redmine1/files/ (tar+gzip)
#
# Backup destinations:
#   - DB dumps:   /opt/redmine/backup/db/
#   - File archives: /opt/redmine/backup/files/
#
# Cron installation (runs daily at 02:00):
#   echo "0 2 * * * root /opt/redmine/containers/scripts/backup.sh >> /var/log/redmine-backup.log 2>&1" \
#       > /etc/cron.d/redmine-backup
#   chmod 644 /etc/cron.d/redmine-backup

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
ENV_FILE="/opt/redmine/containers/.env"
BACKUP_DB_DIR="/opt/redmine/backup/db"
BACKUP_FILES_DIR="/opt/redmine/backup/files"
KEEP_GENERATIONS=7
TIMESTAMP=$(date -u '+%Y%m%d_%H%M%S')
LOG_PREFIX="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [backup]"

# ── Helper functions ───────────────────────────────────────────────────────────
log()  { echo "${LOG_PREFIX} $*"; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }
warn() { echo "${LOG_PREFIX} WARNING: $*" >&2; }

# ── Load environment ───────────────────────────────────────────────────────────
[ -f "${ENV_FILE}" ] || die "Environment file not found: ${ENV_FILE}"
# shellcheck source=/dev/null
source "${ENV_FILE}"

[ -z "${REDMINE_DB_PASSWORD:-}" ] && die "REDMINE_DB_PASSWORD is not set in ${ENV_FILE}"
POSTGRES_ADMIN_PASSWORD="${POSTGRES_PASSWORD:-${POSTGRES_SUPERUSER_PASSWORD:-}}"
[ -z "${POSTGRES_ADMIN_PASSWORD}" ] && die "POSTGRES_PASSWORD or POSTGRES_SUPERUSER_PASSWORD is not set in ${ENV_FILE}"

# ── Verify containers are running ─────────────────────────────────────────────
if ! podman container inspect redmine-db --format '{{.State.Status}}' 2>/dev/null | grep -q 'running'; then
    die "Container 'redmine-db' is not running. Cannot perform backup."
fi

# ── Create backup directories if needed ───────────────────────────────────────
mkdir -p "${BACKUP_DB_DIR}" "${BACKUP_FILES_DIR}"
chmod 750 "${BACKUP_DB_DIR}" "${BACKUP_FILES_DIR}"

log "Starting backup (timestamp: ${TIMESTAMP}) ..."

# ── Function: backup a single database ───────────────────────────────────────
backup_database() {
    local DBNAME="$1"
    local OUTFILE="${BACKUP_DB_DIR}/${DBNAME}_${TIMESTAMP}.dump"

    log "Backing up database: ${DBNAME} → $(basename "${OUTFILE}")"

    PGPASSWORD="${POSTGRES_ADMIN_PASSWORD}" \
    podman exec redmine-db \
        pg_dump \
            -U postgres \
            -F c \
            -Z 6 \
            "${DBNAME}" > "${OUTFILE}"

    local SIZE
    SIZE=$(du -sh "${OUTFILE}" | cut -f1)
    log "  Database backup complete: ${SIZE}"

    # ── Rotate: keep only KEEP_GENERATIONS most recent backups ───────────────
    local COUNT
    COUNT=$(ls -1 "${BACKUP_DB_DIR}/${DBNAME}_"*.dump 2>/dev/null | wc -l)
    if [ "${COUNT}" -gt "${KEEP_GENERATIONS}" ]; then
        log "  Rotating old backups (keeping ${KEEP_GENERATIONS}, found ${COUNT}) ..."
        ls -1t "${BACKUP_DB_DIR}/${DBNAME}_"*.dump \
            | tail -n +"$((KEEP_GENERATIONS + 1))" \
            | xargs rm -f
        log "  Rotation complete."
    fi
}

# ── Function: backup files for a Redmine environment ─────────────────────────
backup_files() {
    local ENV_NUM="$1"        # 1, 2, or 3
    local SOURCE_DIR="/opt/redmine/data/redmine${ENV_NUM}/files"
    local OUTFILE="${BACKUP_FILES_DIR}/redmine${ENV_NUM}_${TIMESTAMP}.tar.gz"

    if [ ! -d "${SOURCE_DIR}" ]; then
        warn "Files directory not found: ${SOURCE_DIR}. Skipping."
        return 0
    fi

    log "Backing up files: redmine${ENV_NUM} → $(basename "${OUTFILE}")"

    tar \
        --create \
        --gzip \
        --file="${OUTFILE}" \
        --directory="$(dirname "${SOURCE_DIR}")" \
        "$(basename "${SOURCE_DIR}")"

    local SIZE
    SIZE=$(du -sh "${OUTFILE}" | cut -f1)
    log "  Files backup complete: ${SIZE}"

    # ── Rotate ───────────────────────────────────────────────────────────────
    local COUNT
    COUNT=$(ls -1 "${BACKUP_FILES_DIR}/redmine${ENV_NUM}_"*.tar.gz 2>/dev/null | wc -l)
    if [ "${COUNT}" -gt "${KEEP_GENERATIONS}" ]; then
        log "  Rotating old file backups (keeping ${KEEP_GENERATIONS}, found ${COUNT}) ..."
        ls -1t "${BACKUP_FILES_DIR}/redmine${ENV_NUM}_"*.tar.gz \
            | tail -n +"$((KEEP_GENERATIONS + 1))" \
            | xargs rm -f
        log "  Rotation complete."
    fi
}

# ── Perform backups ────────────────────────────────────────────────────────────
backup_database "redmine_prod"

backup_files 1

# ── Summary ───────────────────────────────────────────────────────────────────
log "Backup complete."
log "DB backups:   $(ls -1 ${BACKUP_DB_DIR}/*.dump 2>/dev/null | wc -l) files in ${BACKUP_DB_DIR}"
log "File backups: $(ls -1 ${BACKUP_FILES_DIR}/*.tar.gz 2>/dev/null | wc -l) files in ${BACKUP_FILES_DIR}"
