#!/bin/bash
# scripts/restore.sh
#
# redmine スタック向け災害復旧リストアスクリプトです。
#
# 本番は Docker Engine + systemd (systemd/redmine.service) 構成のため、
# docker デーモンを操作できる権限で実行します（root、または docker グループ）。
# スタック全体は systemd ユニット (redmine.service) で管理しますが、この
# スクリプトは redmine-web コンテナだけを止めて DB を入れ替えるため、
# ユニットは停止せずコンテナ単位で stop/start します。
#
# 使い方:
#   bash /opt/redmine/containers/scripts/restore.sh <db_dump> <files_archive>
#
# 引数:
#   db_dump       — backup.sh が作成した .dump ファイル
#   files_archive — backup.sh が作成した .tar.gz ファイル
#
# 実行例:
#   bash scripts/restore.sh \
#       /opt/redmine/backup/db/redmine_20260620_020000.dump \
#       /opt/redmine/backup/files/redmine_20260620_020000.tar.gz

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
if [ -f "${ROOT_DIR}/.env" ]; then
    # shellcheck disable=SC1091
    set -a; source "${ROOT_DIR}/.env"; set +a
fi

SECRETS_DIR="${SECRETS_DIR:-${ROOT_DIR}/secrets}"
DB_PASSWORD_FILE="${DB_PASSWORD_FILE:-${SECRETS_DIR}/db_password.txt}"
DB_CONTAINER="${REDMINE_DB_CONTAINER:-redmine-db}"
DB_NAME="${REDMINE_DB_NAME:-redmine}"
DB_USER="${REDMINE_DB_USER:-redmine}"
WEB_CONTAINER="${REDMINE_WEB_CONTAINER:-redmine-web}"
DATA_DIR="${REDMINE_DATA_DIR:-/opt/redmine/data/redmine}"
FILES_DIR="${DATA_DIR}/files"
# 添付ファイルの所有者。docker の bind mount は UID を変換しないため、
# 展開後にコンテナ内 redmine ユーザーの uid:gid へ揃えます
# （公式 redmine イメージでは 999:999）。
REDMINE_APP_UID="${REDMINE_APP_UID:-999}"
REDMINE_APP_GID="${REDMINE_APP_GID:-999}"
LOG_PREFIX="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [restore]"

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

usage() {
    echo "Usage: $0 <db_dump_file> <files_archive>"
    exit 1
}

[ "$#" -eq 2 ] || usage
DB_DUMP="$1"
FILES_ARCHIVE="$2"

# ── 入力検証 ───────────────────────────────────────────────────────────────────
[ -f "${DB_DUMP}" ]          || die "DB dump file not found: ${DB_DUMP}"
[ -f "${FILES_ARCHIVE}" ]    || die "Files archive not found: ${FILES_ARCHIVE}"
[ -r "${DB_PASSWORD_FILE}" ] || die "DB password file not readable: ${DB_PASSWORD_FILE}"

DB_PASSWORD="$(cat "${DB_PASSWORD_FILE}")"
[ -n "${DB_PASSWORD}" ] || die "DB password file is empty: ${DB_PASSWORD_FILE}"

# ── 安全確認 ───────────────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║           REDMINE DISASTER RECOVERY RESTORE         ║"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║ Container: ${WEB_CONTAINER}"
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

# ── 手順 1: Redmine (web) コンテナ停止 ─────────────────────────────────────────
# redmine-db は起動したまま（この後 psql / pg_restore で使います）、
# アプリだけを止めます。systemd ユニット (redmine.service) は触りません。
log "Step 1/6: Stopping ${WEB_CONTAINER} ..."
if cli container inspect "${WEB_CONTAINER}" --format '{{.State.Status}}' 2>/dev/null | grep -q 'running'; then
    cli stop "${WEB_CONTAINER}" >/dev/null
    log "  ${WEB_CONTAINER} stopped."
else
    log "  ${WEB_CONTAINER} was not running."
fi

# ── 手順 2: DB コンテナ稼働確認 ────────────────────────────────────────────────
log "Step 2/6: Verifying database container ..."
cli container inspect "${DB_CONTAINER}" --format '{{.State.Status}}' 2>/dev/null | grep -q 'running' \
    || die "Container '${DB_CONTAINER}' is not running."
log "  ${DB_CONTAINER} is running."

# コンテナ内 psql / pg_restore はこのパスワードで認証します。
PSQL() { cli exec -e PGPASSWORD="${DB_PASSWORD}" "${DB_CONTAINER}" psql -U "${DB_USER}" "$@"; }

# ── 手順 3: DB を削除して再作成 ──────────────────────────────────────────────
# ★ ここで PostGIS 拡張は作りません（作るのは手順 4 の pg_restore のあと）。
#   backup.sh のダンプは PostGIS 入りの DB から取っているため、ダンプ自身が
#   `CREATE EXTENSION postgis` と `CREATE SCHEMA topology` を含みます。先に
#   postgis_topology を作ってしまうと topology スキーマが二重定義になり、
#   pg_restore が `--exit-on-error` で
#   `ERROR: schema "topology" already exists` を出して中断します。
log "Step 3/6: Recreating database ${DB_NAME} ..."
PSQL -d postgres -c "DROP DATABASE IF EXISTS ${DB_NAME};" || true
PSQL -d postgres -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8' \
    LC_COLLATE 'C.UTF-8' LC_CTYPE 'C.UTF-8' TEMPLATE template0;"
log "  Database ${DB_NAME} recreated (empty)."

# ── 手順 4: ダンプから DB 復元 ───────────────────────────────────────────────
log "Step 4/6: Restoring database from $(basename "${DB_DUMP}") ..."
DUMP_BASENAME=$(basename "${DB_DUMP}")
cli cp "${DB_DUMP}" "${DB_CONTAINER}:/tmp/${DUMP_BASENAME}"
cli exec -e PGPASSWORD="${DB_PASSWORD}" "${DB_CONTAINER}" \
    pg_restore -U "${DB_USER}" -d "${DB_NAME}" --no-owner --role="${DB_USER}" \
        --exit-on-error "/tmp/${DUMP_BASENAME}"
cli exec "${DB_CONTAINER}" rm -f "/tmp/${DUMP_BASENAME}"
# ダンプに PostGIS が含まれていなかった場合の保険（含まれていれば no-op）。
# redmine_gtt は postgis / postgis_topology が無いと起動できません。
PSQL -d "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS postgis;" >/dev/null
PSQL -d "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS postgis_topology;" >/dev/null
log "  Database restore complete (PostGIS extensions verified)."

# ── 手順 5: 添付ファイル復元 ─────────────────────────────────────────────────
log "Step 5/6: Restoring files from $(basename "${FILES_ARCHIVE}") ..."
mkdir -p "${FILES_DIR}"
rm -rf "${FILES_DIR:?}"/*
tar -xzf "${FILES_ARCHIVE}" -C "${DATA_DIR}/"
# bind mount では所有者がそのままコンテナ内に見えるため、アプリ
# （コンテナ内 redmine ユーザー）が書き込めるように揃えます。
if [ "$(id -u)" = "0" ]; then
    chown -R "${REDMINE_APP_UID}:${REDMINE_APP_GID}" "${FILES_DIR}"
else
    warn "Not running as root — skipped chown of ${FILES_DIR} to ${REDMINE_APP_UID}:${REDMINE_APP_GID}."
    warn "If the app cannot write attachments, run: sudo chown -R ${REDMINE_APP_UID}:${REDMINE_APP_GID} ${FILES_DIR}"
fi
log "  Files restore complete."

# ── 手順 6: Redmine (web) コンテナ再起動 ──────────────────────────────────────
log "Step 6/6: Restarting ${WEB_CONTAINER} ..."
cli start "${WEB_CONTAINER}" >/dev/null
log "  ${WEB_CONTAINER} started."
log ""
log "Restore complete. Monitor startup:"
log "  ${CONTAINER_CLI} logs -f ${WEB_CONTAINER}"
log "  (systemd 側の状態は 'systemctl status redmine' で確認できます)"
