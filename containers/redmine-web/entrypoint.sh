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
#   2. config/database.yml（REDMINE_DB_ADAPTER 既定 postgis）と
#      config/configuration.yml を描画
#   3. データベース接続待機（PostgreSQL: pg_isready / MySQL: mysql クライアント）
#   4. コア/プラグインの DB マイグレーション実行
#      （公式イメージ同様 REDMINE_NO_DB_MIGRATE / REDMINE_PLUGINS_MIGRATE で制御）
#   4.5. 初回起動時のみ既定データ（日本語）を投入
#      （REDMINE_LOAD_DEFAULT_DATA / REDMINE_DEFAULT_DATA_LANG で制御）
#   4.9. REDMINE_MIGRATE_ONLY があればここで終了（Web サーバーを起動しない）
#   5. アプリサーバー起動（REDMINE_WEB_SERVER で切り替え、サブ URI /redmine）
#      puma      (既定) Apache(:80) 起動後、`rails server` で Puma(:3000) 起動
#      passenger Apache(:80) を foreground 起動。mod_passenger が Redmine を
#                直接起動するため Puma は起動しません。
#
# パスワードはイメージへ焼き込まず、平文環境変数でも渡しません。
# *_FILE で参照されるシークレットファイルから読み込みます。

set -euo pipefail

REDMINE_HOME="${REDMINE_HOME:-/usr/src/redmine}"
RAILS_ENV="${RAILS_ENV:-production}"
RAILS_RELATIVE_URL_ROOT="${RAILS_RELATIVE_URL_ROOT:-/redmine}"
# REDMINE_HOME は passenger 用 Apache テンプレート（PassengerAppRoot /
# DocumentRoot / Alias）の envsubst でも参照するため export します。
export REDMINE_HOME RAILS_ENV RAILS_RELATIVE_URL_ROOT

REDMINE_DB_HOST="${REDMINE_DB_HOST:-redmine-db}"
REDMINE_DB_NAME="${REDMINE_DB_NAME:-redmine}"
REDMINE_DB_USER="${REDMINE_DB_USER:-redmine}"
# データベースアダプタ。既定は postgis で、これがこのスタックの通常構成です
# （redmine_gtt が必須とするため。CLAUDE.md / docs/Design.md 参照）。
# mysql2 / postgresql を使うのは移行検証用の Containerfile.v5-mysql
# （Redmine 5.1.6）だけです（docs/Upgrade.md）。
#   postgis     6 系 / 7 系の通常構成（config/database.yml.tmpl を描画）
#   postgresql  コンバート途中の 5.1.6（config/database.postgresql.yml.tmpl）
#   mysql2      移行元の 5.1.6 + MySQL 8.0（config/database.mysql2.yml.tmpl）
REDMINE_DB_ADAPTER="${REDMINE_DB_ADAPTER:-postgis}"
case "${REDMINE_DB_ADAPTER}" in
    postgis|postgresql) REDMINE_DB_PORT="${REDMINE_DB_PORT:-5432}" ;;
    mysql2)             REDMINE_DB_PORT="${REDMINE_DB_PORT:-3306}" ;;
    *) echo "ERROR: REDMINE_DB_ADAPTER must be 'postgis', 'postgresql' or 'mysql2' (got '${REDMINE_DB_ADAPTER}')." >&2; exit 1 ;;
esac
REDMINE_PUMA_PORT="${REDMINE_PUMA_PORT:-3000}"
# アプリサーバーの選択。イメージにはどちらも同梱してあるため、
# .env / Environment= の変更とコンテナ再起動だけで切り替わります
# （イメージ再ビルドは不要）。
#   puma      Apache -> ProxyPass -> Puma(:${REDMINE_PUMA_PORT})
#   passenger Apache + mod_passenger が Redmine を直接起動（:3000 なし）
REDMINE_WEB_SERVER="${REDMINE_WEB_SERVER:-puma}"
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
# 初回起動時（roles テーブルが空 = load_default_data 未実行）のみ、
# 既定データ（トラッカー/ロール/ワークフロー等）を REDMINE_DEFAULT_DATA_LANG
# 言語で読み込みます。REDMINE_LOAD_DEFAULT_DATA を空にすると無効化できます。
REDMINE_LOAD_DEFAULT_DATA="${REDMINE_LOAD_DEFAULT_DATA:-1}"
REDMINE_DEFAULT_DATA_LANG="${REDMINE_DEFAULT_DATA_LANG:-ja}"
# 値あり（非空かつ != 0）なら、設定描画とマイグレーションまで実行して
# Web サーバーを起動せずに終了します。アップグレード作業でアプリを公開せずに
# マイグレーションだけ流したいとき、および MySQL → PostgreSQL コンバートで
# 空 DB に Rails スキーマだけ作るときに使います（docs/Upgrade.md）。
REDMINE_MIGRATE_ONLY="${REDMINE_MIGRATE_ONLY:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [redmine-web] $*"; }
die() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [redmine-web] ERROR: $*" >&2; exit 1; }

case "${REDMINE_WEB_SERVER}" in
    puma|passenger) ;;
    *) die "REDMINE_WEB_SERVER must be 'puma' or 'passenger' (got '${REDMINE_WEB_SERVER}')." ;;
esac
export REDMINE_WEB_SERVER

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
export REDMINE_DB_ADAPTER
export SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD
export SECRET_KEY_BASE REDMINE_PUMA_PORT

cd "${REDMINE_HOME}"

# ── 2. テンプレートから設定描画 ───────────────────────────────────────────────
# アダプタ別テンプレートがあればそれを、無ければ既定（postgis 用の
# config/database.yml.tmpl）を描画します。どのテンプレートをイメージに含めるかは
# 各 Containerfile 側の責務で、entrypoint.sh には系列ごとの分岐を置きません。
DB_TEMPLATE="config/database.yml.tmpl"
if [[ -r "config/database.${REDMINE_DB_ADAPTER}.yml.tmpl" ]]; then
    DB_TEMPLATE="config/database.${REDMINE_DB_ADAPTER}.yml.tmpl"
fi
[[ -r "${DB_TEMPLATE}" ]] || die "Database template ${DB_TEMPLATE} is missing from the image."

log "Rendering config/database.yml (${REDMINE_DB_ADAPTER} adapter, from ${DB_TEMPLATE}) ..."
# shellcheck disable=SC2016
envsubst '${REDMINE_DB_HOST} ${REDMINE_DB_PORT} ${REDMINE_DB_NAME} ${REDMINE_DB_USER} ${REDMINE_DB_PASSWORD}' \
    < "${DB_TEMPLATE}" > config/database.yml
chown redmine:redmine config/database.yml
chmod 640 config/database.yml

log "Rendering config/configuration.yml ..."
# shellcheck disable=SC2016
envsubst '${SMTP_HOST} ${SMTP_PORT} ${SMTP_USER} ${SMTP_PASSWORD}' \
    < config/configuration.yml.tmpl > config/configuration.yml
chown redmine:redmine config/configuration.yml
chmod 640 config/configuration.yml

# Render from the .tmpl source, not the previously-rendered .conf — conf-enabled/
# is a symlink to conf-available/<name>.conf (via a2enconf), so reading
# and writing that same .conf here would truncate it to empty before envsubst
# ever reads it.
# Both configs render a *:80 VirtualHost, so exactly one of them may be enabled.
if [[ "${REDMINE_WEB_SERVER}" == "passenger" ]]; then
    # 移行検証用の 5.1.6 イメージ (Containerfile.v5-mysql) は mod_passenger を
    # 同梱していません。a2enmod の分かりにくい失敗ではなく理由を出して止めます。
    [[ -r /etc/apache2/conf-available/redmine-passenger.conf.tmpl ]] \
        || die "REDMINE_WEB_SERVER=passenger is not supported by this image (mod_passenger not installed)."
    log "Rendering Apache + mod_passenger config ..."
    # shellcheck disable=SC2016
    envsubst '${RAILS_RELATIVE_URL_ROOT} ${REDMINE_HOME} ${RAILS_ENV}' \
        < /etc/apache2/conf-available/redmine-passenger.conf.tmpl \
        > /etc/apache2/conf-available/redmine-passenger.conf
    a2enmod passenger >/dev/null
    # a2disconf は conf-available に該当ファイルが無いと非 0 で終了するため、
    # 反対モードの conf が未描画のケースを握りつぶします。
    a2disconf redmine-proxy >/dev/null 2>&1 || true
    a2enconf redmine-passenger >/dev/null
else
    log "Rendering Apache reverse-proxy config ..."
    # shellcheck disable=SC2016
    envsubst '${RAILS_RELATIVE_URL_ROOT} ${REDMINE_PUMA_PORT}' \
        < /etc/apache2/conf-available/redmine-proxy.conf.tmpl \
        > /etc/apache2/conf-available/redmine-proxy.conf
    # mod_passenger を同梱しないイメージ（Containerfile.v5-mysql）では
    # a2dismod がモジュール不在で非 0 終了するため握りつぶします。
    a2dismod -f passenger >/dev/null 2>&1 || true
    # a2disconf は conf-available に該当ファイルが無いと非 0 で終了するため、
    # 反対モードの conf が未描画のケースを握りつぶします。
    a2disconf redmine-passenger >/dev/null 2>&1 || true
    a2enconf redmine-proxy >/dev/null
fi

# ── 3. データベース待機 ───────────────────────────────────────────────────────
# PostgreSQL は pg_isready、MySQL は mysql クライアントで実接続を試します
# （mysqladmin ping はサーバーが生きていれば認証失敗でも通ることがあるため、
#   対象 DB へ SELECT 1 できるところまで確認します）。
export PGPASSWORD="${REDMINE_DB_PASSWORD}"
export MYSQL_PWD="${REDMINE_DB_PASSWORD}"

db_ready() {
    if [[ "${REDMINE_DB_ADAPTER}" == "mysql2" ]]; then
        mysql --protocol=TCP -h "${REDMINE_DB_HOST}" -P "${REDMINE_DB_PORT}" \
            -u "${REDMINE_DB_USER}" -D "${REDMINE_DB_NAME}" \
            -e 'SELECT 1' >/dev/null 2>&1
    else
        pg_isready -h "${REDMINE_DB_HOST}" -p "${REDMINE_DB_PORT}" -U "${REDMINE_DB_USER}" \
            -d "${REDMINE_DB_NAME}" -q 2>/dev/null
    fi
}

log "Waiting for the database (${REDMINE_DB_ADAPTER}) at ${REDMINE_DB_HOST}:${REDMINE_DB_PORT} ..."
MAX_WAIT=120
WAITED=0
until db_ready; do
    [[ ${WAITED} -ge ${MAX_WAIT} ]] && die "Database not ready after ${MAX_WAIT}s."
    sleep 2
    (( WAITED += 2 ))
done
log "Database is ready."

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

# ── 4.5 初期データ投入（初回のみ） ───────────────────────────────────────────
# load_default_data はトラッカー/ワークフロー/カスタムロール等を新規作成する
# ため、既に投入済みの DB に対して再実行すると重複データを作ってしまいます。
# trackers テーブルが空（= 未投入）かどうかで初回起動を判定します。
# 注意: roles テーブルは使えません — コアマイグレーションが load_default_data
# 実行前から "Non member"/"Anonymous" の 2 件を常に作成済みのため、
# roles の有無では初回判定ができません。
count_trackers() {
    if [[ "${REDMINE_DB_ADAPTER}" == "mysql2" ]]; then
        mysql --protocol=TCP -h "${REDMINE_DB_HOST}" -P "${REDMINE_DB_PORT}" \
            -u "${REDMINE_DB_USER}" -D "${REDMINE_DB_NAME}" \
            -N -B -e 'SELECT count(*) FROM trackers;' 2>/dev/null || echo ""
    else
        psql -h "${REDMINE_DB_HOST}" -p "${REDMINE_DB_PORT}" -U "${REDMINE_DB_USER}" \
            -d "${REDMINE_DB_NAME}" -tAc 'SELECT count(*) FROM trackers;' 2>/dev/null || echo ""
    fi
}

if [[ -n "${REDMINE_LOAD_DEFAULT_DATA}" && "${REDMINE_LOAD_DEFAULT_DATA}" != "0" ]]; then
    TRACKER_COUNT="$(count_trackers)"
    if [[ "${TRACKER_COUNT}" == "0" ]]; then
        log "Loading default data (lang=${REDMINE_DEFAULT_DATA_LANG}) for first-time setup ..."
        REDMINE_LANG="${REDMINE_DEFAULT_DATA_LANG}" bundle exec rake redmine:load_default_data RAILS_ENV="${RAILS_ENV}"
    else
        log "Default data already present (trackers=${TRACKER_COUNT:-unknown}) — skipping load_default_data."
    fi
else
    log "REDMINE_LOAD_DEFAULT_DATA unset/0 — skipping default data load."
fi

# ── 4.9 マイグレーション専用モード ───────────────────────────────────────────
# REDMINE_MIGRATE_ONLY が設定されていれば、ここで正常終了します。
# Apache も Puma も起動しないため、アプリを公開せずにマイグレーションだけを
# 適用できます（アップグレード前の片道処理、および MySQL → PostgreSQL
# コンバートで空 DB に Rails スキーマだけを作る用途。docs/Upgrade.md 参照）。
if [[ -n "${REDMINE_MIGRATE_ONLY}" && "${REDMINE_MIGRATE_ONLY}" != "0" ]]; then
    log "REDMINE_MIGRATE_ONLY set — migrations finished, exiting without starting a web server."
    exit 0
fi

# ── 5. アプリサーバー起動 ─────────────────────────────────────────────────────
# passenger モードでは Puma を起動しません。mod_passenger が Apache の
# 子プロセスとして Redmine を起動するため、Apache を foreground で exec して
# PID 1 にします（SIGTERM がそのまま Apache に届き、停止が素直になります）。
#
# Passenger の native support 拡張はビルド時に用意していません。初回 spawn 時に
# 自動コンパイルが試みられ、失敗しても pure-Ruby 実装へフォールバックします
# （error log に警告が出るだけで致命的ではありません）。
if [[ "${REDMINE_WEB_SERVER}" == "passenger" ]]; then
    log "Starting Apache HTTPD on :80 with mod_passenger (sub-URI ${RAILS_RELATIVE_URL_ROOT}) ..."
    # APACHE_RUN_USER / APACHE_PID_FILE 等の Debian 既定値を読み込みます。
    # shellcheck source=/dev/null
    source /etc/apache2/envvars
    # envvars はパスを export するだけでディレクトリは作りません（作るのは
    # apache2ctl 側）。Podman は /run に tmpfs をマウントするため、イメージに
    # 含まれる /run/apache2 は起動時に消えています。ここで作り直します。
    mkdir -p "${APACHE_RUN_DIR:-/var/run/apache2}" "${APACHE_LOCK_DIR:-/var/lock/apache2}"
    if [[ -n "${APACHE_PID_FILE:-}" ]]; then
        rm -f "${APACHE_PID_FILE}"
    fi
    exec apache2 -DFOREGROUND
fi

# ── puma モード: Apache + Puma 起動（PID 1 が両プロセスを監視） ──────────────
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
