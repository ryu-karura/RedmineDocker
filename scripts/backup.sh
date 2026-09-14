#!/bin/bash
# scripts/backup.sh
#
# redmine スタック向け自動バックアップスクリプトです。
# バックアップ世代は常に 7 世代保持します。
#
# バックアップ対象:
#   - PostgreSQL データベース: redmine（pg_dump カスタム形式）
#   - 添付ファイル: /opt/redmine/data/redmine/files/（tar+gzip）
#
# 出力先:
#   - DB ダンプ:      /opt/redmine/backup/db/
#   - ファイルアーカイブ: /opt/redmine/backup/files/
#
# 本番は Docker Engine + systemd (systemd/redmine.service) 構成のため、
# docker デーモンを操作できる権限が必要です（root、または docker グループ）。
# Cron 設定例（毎日 02:00、root の crontab: `sudo crontab -e`）:
#   0 2 * * * /opt/redmine/containers/scripts/backup.sh >> /opt/redmine/backup/backup.log 2>&1
# docker が無い環境では podman へ自動フォールバックします（CONTAINER_CLI）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
if [ -f "${ROOT_DIR}/.env" ]; then
    # shellcheck disable=SC1091
    set -a; source "${ROOT_DIR}/.env"; set +a
fi

# ── 設定値 ─────────────────────────────────────────────────────────────────────
SECRETS_DIR="${SECRETS_DIR:-/opt/redmine/containers/secrets}"
DB_PASSWORD_FILE="${DB_PASSWORD_FILE:-${SECRETS_DIR}/db_password.txt}"
BACKUP_DB_DIR="/opt/redmine/backup/db"
BACKUP_FILES_DIR="/opt/redmine/backup/files"
FILES_SOURCE_DIR="/opt/redmine/data/redmine/files"
DB_CONTAINER="${REDMINE_DB_CONTAINER:-redmine-db}"
DB_NAME="${REDMINE_DB_NAME:-redmine}"
DB_USER="${REDMINE_DB_USER:-redmine}"
FILES_ARCHIVE_PREFIX="${REDMINE_FILES_ARCHIVE_PREFIX:-redmine}"
KEEP_GENERATIONS=7
TIMESTAMP=$(date -u '+%Y%m%d_%H%M%S')
LOG_PREFIX="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [backup]"

# ── ヘルパー関数 ────────────────────────────────────────────────────────────────
log()  { echo "${LOG_PREFIX} $*"; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }
warn() { echo "${LOG_PREFIX} WARNING: $*" >&2; }

# ── コンテナ CLI ───────────────────────────────────────────────────────────────
# 本番・開発とも Docker Engine を既定にし、docker が無い環境（rootless Podman
# だけの WSL など）では podman へフォールバックします。CONTAINER_CLI で明示指定も可。
CONTAINER_CLI="${CONTAINER_CLI:-}"
if [ -z "${CONTAINER_CLI}" ]; then
    if command -v docker >/dev/null 2>&1; then
        CONTAINER_CLI=docker
    elif command -v podman >/dev/null 2>&1; then
        CONTAINER_CLI=podman
    else
        die "Neither docker nor podman found. Set CONTAINER_CLI explicitly."
    fi
fi
cli() { "${CONTAINER_CLI}" "$@"; }

# ── DB パスワード読込（Docker/Podman シークレットファイル） ─────────────────
[ -r "${DB_PASSWORD_FILE}" ] || die "DB password file not readable: ${DB_PASSWORD_FILE}"
DB_PASSWORD="$(cat "${DB_PASSWORD_FILE}")"
[ -n "${DB_PASSWORD}" ] || die "DB password file is empty: ${DB_PASSWORD_FILE}"

# ── DB コンテナ稼働確認 ─────────────────────────────────────────────────────────
if ! cli container inspect "${DB_CONTAINER}" --format '{{.State.Status}}' 2>/dev/null | grep -q 'running'; then
    die "Container '${DB_CONTAINER}' is not running. Cannot perform backup."
fi

# ── 必要に応じてバックアップディレクトリ作成 ─────────────────────────────────
mkdir -p "${BACKUP_DB_DIR}" "${BACKUP_FILES_DIR}"
chmod 750 "${BACKUP_DB_DIR}" "${BACKUP_FILES_DIR}"

log "Starting backup (timestamp: ${TIMESTAMP}) ..."

# ── 関数: DB バックアップ ───────────────────────────────────────────────────────
backup_database() {
    local OUTFILE="${BACKUP_DB_DIR}/${DB_NAME}_${TIMESTAMP}.dump"

    log "Backing up database: ${DB_NAME} → $(basename "${OUTFILE}")"

    cli exec -e PGPASSWORD="${DB_PASSWORD}" "${DB_CONTAINER}" \
        pg_dump -U "${DB_USER}" -F c -Z 6 "${DB_NAME}" > "${OUTFILE}"

    local SIZE
    SIZE=$(du -sh "${OUTFILE}" | cut -f1)
    log "  Database backup complete: ${SIZE}"

    # ── ローテーション: 新しい KEEP_GENERATIONS 件だけ保持 ───────────────────
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

# ── 関数: 添付ファイルバックアップ ────────────────────────────────────────────
backup_files() {
    local OUTFILE="${BACKUP_FILES_DIR}/${FILES_ARCHIVE_PREFIX}_${TIMESTAMP}.tar.gz"

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

    # ── ローテーション ───────────────────────────────────────────────────────
    local COUNT
    COUNT=$(find "${BACKUP_FILES_DIR}" -maxdepth 1 -type f -regex ".*/${FILES_ARCHIVE_PREFIX}_[0-9]{8}_[0-9]{6}\.tar\.gz" 2>/dev/null | wc -l)
    if [ "${COUNT}" -gt "${KEEP_GENERATIONS}" ]; then
        log "  Rotating old file backups (keeping ${KEEP_GENERATIONS}, found ${COUNT}) ..."
        find "${BACKUP_FILES_DIR}" -maxdepth 1 -type f -regex ".*/${FILES_ARCHIVE_PREFIX}_[0-9]{8}_[0-9]{6}\.tar\.gz" -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr \
            | cut -d' ' -f2- \
            | tail -n +"$((KEEP_GENERATIONS + 1))" \
            | xargs rm -f
        log "  Rotation complete."
    fi
}

# ── バックアップ実行 ───────────────────────────────────────────────────────────
backup_database
backup_files

# ── サマリー ───────────────────────────────────────────────────────────────────
log "Backup complete."
log "DB backups:   $(find "${BACKUP_DB_DIR}" -maxdepth 1 -type f -regex ".*/.*\.dump" 2>/dev/null | wc -l) files in ${BACKUP_DB_DIR}"
log "File backups: $(find "${BACKUP_FILES_DIR}" -maxdepth 1 -type f -regex ".*/.*\.tar\.gz" 2>/dev/null | wc -l) files in ${BACKUP_FILES_DIR}"
