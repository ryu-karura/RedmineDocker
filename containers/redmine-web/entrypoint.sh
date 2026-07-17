#!/bin/bash
# containers/redmine-web/entrypoint.sh
#
# redmine-web コンテナ用 entrypoint
# （Redmine 6.1.3 + 公式イメージ + プラグインスタック）。
# Apache が TCP :80 を bind するため root で起動し、
# Puma は非特権 `redmine` ユーザーで起動します。
#
# 処理順序:
#   1. シークレット解決（Docker/Podman の *_FILE 参照に対応）
#   2. config/database.yml（postgis）と config/configuration.yml を描画
#   3. PostgreSQL 接続待機
#   4. コア/プラグインの DB マイグレーション実行
#      （公式イメージ同様 REDMINE_NO_DB_MIGRATE / REDMINE_PLUGINS_MIGRATE で制御）
#   5. Apache(:80) 起動後、`rails server` で Puma(:3000) 起動
#      （サブ URI /redmine）
#
# パスワードはイメージへ焼き込まず、平文環境変数でも渡しません。
# *_FILE で参照されるシークレットファイルから読み込みます。

set -euo pipefail

REDMINE_HOME="${REDMINE_HOME:-/usr/src/redmine}"
RAILS_ENV="${RAILS_ENV:-production}"
RAILS_RELATIVE_URL_ROOT="${RAILS_RELATIVE_URL_ROOT:-/redmine}"
export RAILS_ENV RAILS_RELATIVE_URL_ROOT

REDMINE_DB_HOST="${REDMINE_DB_HOST:-redmine-db}"
REDMINE_DB_NAME="${REDMINE_DB_NAME:-redmine}"
REDMINE_DB_USER="${REDMINE_DB_USER:-redmine}"
REDMINE_DB_PORT="${REDMINE_DB_PORT:-5432}"
REDMINE_PUMA_PORT="${REDMINE_PUMA_PORT:-3000}"
SMTP_HOST="${SMTP_HOST:-localhost}"
SMTP_PORT="${SMTP_PORT:-25}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
# マイグレーションスイッチは公式 redmine イメージの docker-entrypoint.sh と同様:
#   REDMINE_NO_DB_MIGRATE   値あり（非空）→ コア `rake db:migrate` をスキップ
#   REDMINE_PLUGINS_MIGRATE 値あり（非空）→ `rake redmine:plugins:migrate` 実行
# upstream との差分は既定値のみです。
# upstream は両方未設定（コアのみ migrate）ですが、このスタックは
# 13 プラグインを同梱するため、起動ごとに plugin migrate する目的で
# REDMINE_PLUGINS_MIGRATE=1 を既定にしています。
REDMINE_NO_DB_MIGRATE="${REDMINE_NO_DB_MIGRATE:-}"
REDMINE_PLUGINS_MIGRATE="${REDMINE_PLUGINS_MIGRATE:-1}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [redmine-web] $*"; }
die() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [redmine-web] ERROR: $*" >&2; exit 1; }

# ── 1. シークレット解決 ────────────────────────────────────────────────────────
# resolve_secret VAR:
#   ${VAR}_FILE が設定されていればそのファイル内容を読む。
#   未設定なら ${VAR} の値をそのまま使う。
#   解決結果が空なら失敗させる。
resolve_secret() {
    local name="$1" file_var="${1}_FILE" file val
    file="$(printf '%s' "${!file_var:-}")"
    if [[ -n "${file}" ]]; then
        [[ -r "${file}" ]] || die "${file_var}=${file} is not readable."
        val="$(cat "${file}")"
    else
        val="${!name:-}"
    fi
    printf '%s' "${val}"
}

REDMINE_DB_PASSWORD="$(resolve_secret REDMINE_DB_PASSWORD)"
[[ -n "${REDMINE_DB_PASSWORD}" ]] \
    || die "REDMINE_DB_PASSWORD (or REDMINE_DB_PASSWORD_FILE) is not set."

# 記事準拠で REDMINE_SECRET_KEY_BASE(_FILE) を優先し、
# 未設定時は REDMINE_SECRET_TOKEN へフォールバックします。
SECRET_KEY_BASE="$(resolve_secret REDMINE_SECRET_KEY_BASE)"
if [[ -z "${SECRET_KEY_BASE}" ]]; then
    SECRET_KEY_BASE="$(resolve_secret REDMINE_SECRET_TOKEN)"
fi
[[ -n "${SECRET_KEY_BASE}" ]] \
    || die "REDMINE_SECRET_KEY_BASE(_FILE) or REDMINE_SECRET_TOKEN(_FILE) is not set."

export REDMINE_DB_HOST REDMINE_DB_NAME REDMINE_DB_USER REDMINE_DB_PASSWORD REDMINE_DB_PORT
export SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD
export SECRET_KEY_BASE REDMINE_PUMA_PORT

cd "${REDMINE_HOME}"

# ── 2. テンプレートから設定描画 ───────────────────────────────────────────────
log "Rendering config/database.yml (postgis adapter) ..."
# shellcheck disable=SC2016
envsubst '${REDMINE_DB_HOST} ${REDMINE_DB_NAME} ${REDMINE_DB_USER} ${REDMINE_DB_PASSWORD}' \
    < config/database.yml.tmpl > config/database.yml
chown redmine:redmine config/database.yml
chmod 640 config/database.yml

log "Rendering config/configuration.yml ..."
# shellcheck disable=SC2016
envsubst '${SMTP_HOST} ${SMTP_PORT} ${SMTP_USER} ${SMTP_PASSWORD}' \
    < config/configuration.yml.tmpl > config/configuration.yml
chown redmine:redmine config/configuration.yml
chmod 640 config/configuration.yml

log "Rendering Apache reverse-proxy config ..."
# shellcheck disable=SC2016
envsubst '${RAILS_RELATIVE_URL_ROOT} ${REDMINE_PUMA_PORT}' \
    < /etc/apache2/conf-available/redmine-proxy.conf > /etc/apache2/conf-enabled/redmine-proxy.conf

# ── 3. PostgreSQL 待機 ────────────────────────────────────────────────────────
log "Waiting for PostgreSQL at ${REDMINE_DB_HOST}:${REDMINE_DB_PORT} ..."
export PGPASSWORD="${REDMINE_DB_PASSWORD}"
MAX_WAIT=120
WAITED=0
until pg_isready -h "${REDMINE_DB_HOST}" -p "${REDMINE_DB_PORT}" -U "${REDMINE_DB_USER}" \
        -d "${REDMINE_DB_NAME}" -q 2>/dev/null; do
    [[ ${WAITED} -ge ${MAX_WAIT} ]] && die "PostgreSQL not ready after ${MAX_WAIT}s."
    sleep 2
    (( WAITED += 2 ))
done
log "PostgreSQL is ready."

# ── 4. データベースマイグレーション ───────────────────────────────────────────
if [[ -z "${REDMINE_NO_DB_MIGRATE}" ]]; then
    log "Running core database migrations ..."
    bundle exec rake db:migrate
else
    log "REDMINE_NO_DB_MIGRATE set — skipping core database migrations."
fi

if [[ -n "${REDMINE_PLUGINS_MIGRATE}" && "${REDMINE_PLUGINS_MIGRATE}" != "0" ]]; then
    log "Running plugin migrations ..."
    bundle exec rake redmine:plugins:migrate
else
    log "REDMINE_PLUGINS_MIGRATE unset/0 — skipping plugin migrations."
fi

# ── 5. Apache + Puma 起動（PID 1 が両プロセスを監視） ────────────────────────
cleanup() {
    local status="${1:-0}"
    trap - EXIT INT TERM
    log "Stopping Apache HTTPD ..."
    apache2ctl -k stop >/dev/null 2>&1 || true
    if [[ -n "${puma_pid:-}" ]] && kill -0 "${puma_pid}" 2>/dev/null; then
        log "Stopping Puma ..."
        kill "${puma_pid}" 2>/dev/null || true
        wait "${puma_pid}" 2>/dev/null || true
    fi
    exit "${status}"
}
trap 'cleanup $?' EXIT
trap 'cleanup 143' INT
trap 'cleanup 143' TERM

log "Starting Apache HTTPD on :80 ..."
apache2ctl -k start

log "Starting Puma via rails server on :${REDMINE_PUMA_PORT} (sub-URI ${RAILS_RELATIVE_URL_ROOT}) ..."
if command -v runuser >/dev/null 2>&1; then
    runuser -u redmine -- /bin/bash -lc "cd '${REDMINE_HOME}' && exec env RAILS_RELATIVE_URL_ROOT='${RAILS_RELATIVE_URL_ROOT}' bundle exec rails server -b 0.0.0.0 -p '${REDMINE_PUMA_PORT}' -e '${RAILS_ENV}'" &
else
    su -s /bin/bash redmine -c "cd '${REDMINE_HOME}' && exec env RAILS_RELATIVE_URL_ROOT='${RAILS_RELATIVE_URL_ROOT}' bundle exec rails server -b 0.0.0.0 -p '${REDMINE_PUMA_PORT}' -e '${RAILS_ENV}'" &
fi
puma_pid=$!
wait "${puma_pid}"
