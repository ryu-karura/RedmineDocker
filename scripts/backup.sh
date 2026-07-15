#!/bin/bash
# scripts/backup.sh
#
# Automated backup script for the hwins Redmine stack.
# Retains exactly 7 generations of backups.
#
# Backup scope:
#   - PostgreSQL database: redmine (pg_dump custom format)
#   - Uploaded files:      /opt/hwins/data/redmine/files/ (tar+gzip)
#
# Backup destinations:
#   - DB dumps:      /opt/hwins/backup/db/
#   - File archives: /opt/hwins/backup/files/
#
# Cron installation (runs daily at 02:00):
#   echo "0 2 * * * root /opt/hwins/containers/scripts/backup.sh >> /var/log/hwins-backup.log 2>&1" \
#       > /etc/cron.d/hwins-backup
#   chmod 644 /etc/cron.d/hwins-backup

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
SECRETS_DIR="${SECRETS_DIR:-/opt/hwins/containers/secrets}"
DB_PASSWORD_FILE="${DB_PASSWORD_FILE:-${SECRETS_DIR}/db_password.txt}"
BACKUP_DB_DIR="/opt/hwins/backup/db"
BACKUP_FILES_DIR="/opt/hwins/backup/files"
FILES_SOURCE_DIR="/opt/hwins/data/redmine/files"
DB_CONTAINER="hwins-db"
DB_NAME="redmine"
DB_USER="redmine"
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
    COUNT=$(ls -1 "${BACKUP_DB_DIR}/${DB_NAME}_"*.dump 2>/dev/null | wc -l)
    if [ "${COUNT}" -gt "${KEEP_GENERATIONS}" ]; then
        log "  Rotating old backups (keeping ${KEEP_GENERATIONS}, found ${COUNT}) ..."
        ls -1t "${BACKUP_DB_DIR}/${DB_NAME}_"*.dump \
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
    COUNT=$(ls -1 "${BACKUP_FILES_DIR}/redmine_"*.tar.gz 2>/dev/null | wc -l)
    if [ "${COUNT}" -gt "${KEEP_GENERATIONS}" ]; then
        log "  Rotating old file backups (keeping ${KEEP_GENERATIONS}, found ${COUNT}) ..."
        ls -1t "${BACKUP_FILES_DIR}/redmine_"*.tar.gz \
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
log "DB backups:   $(ls -1 "${BACKUP_DB_DIR}"/*.dump 2>/dev/null | wc -l) files in ${BACKUP_DB_DIR}"
log "File backups: $(ls -1 "${BACKUP_FILES_DIR}"/*.tar.gz 2>/dev/null | wc -l) files in ${BACKUP_FILES_DIR}"
