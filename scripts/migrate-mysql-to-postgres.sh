#!/bin/bash
# scripts/migrate-mysql-to-postgres.sh
#
# 移行元 Redmine 5.1.1 の MySQL 8.0 データベースを、移行先の
# PostgreSQL 18 + PostGIS 3.6 (redmine-db) へコンバートします。
# Redmine 7 へのアップグレードはこのスクリプトの範囲外です — DB を
# PostgreSQL へ移し替えるところまでを担当します（手順全体は docs/Upgrade.md）。
#
# 方式: 「スキーマは Rails、データは pgloader」
#   1. schema    空の PostgreSQL に対し、移行元とまったく同じ Redmine 5.1.1 +
#                同じプラグイン構成のイメージで `rake db:migrate` を実行し、
#                Rails が期待するスキーマ（serial 列・boolean 列・索引）を作る。
#                REDMINE_MIGRATE_ONLY=1 なので Web サーバーは起動しません。
#   2. data      pgloader を "data only" で実行し、テーブルの中身だけを転送する。
#   3. sequences serial 列のシーケンスを最大 id に合わせ直す。
#   4. files     添付ファイルのボリュームを移行先ボリュームへコピーする。
#   5. verify    テーブルごとの件数一致・シーケンス・型を検証する。
#
#   pgloader にスキーマ生成まで任せない理由は
#   scripts/pgloader/redmine-data-only.load.tmpl のヘッダを参照してください。
#
# ★ 破壊的です。移行先 PostgreSQL の該当テーブルを truncate してから流し込みます。
#   実行には RESTORE 同様の明示確認（MIGRATE と入力）が必要です（--yes で省略可）。
#
# 前提:
#   - 移行元スタックが起動していること   docker compose -f compose.legacy.yaml up -d
#   - 移行先 DB が起動していること       docker compose -f compose.dev.yaml up -d redmine-db
#   - 移行先 Web は停止していること      （起動していると migrate が競合します）
#   - secrets/ が生成済みであること      bash scripts/generate-secrets.sh
#
# 使い方:
#   bash scripts/migrate-mysql-to-postgres.sh                 # 全ステップ
#   bash scripts/migrate-mysql-to-postgres.sh --steps verify  # 検証だけ
#   bash scripts/migrate-mysql-to-postgres.sh --steps schema,data,sequences
#   bash scripts/migrate-mysql-to-postgres.sh --yes           # 確認プロンプトを省略
#   bash scripts/migrate-mysql-to-postgres.sh \
#       --exclude-tables client_applications,oauth_nonces,oauth_tokens
#     移行元に、既にアンインストール済みのプラグインが残したテーブル（プラグイン
#     フォルダは無いがマイグレーションだけ残っている「孤立テーブル」）がある場合に
#     指定します。schema ステップの突き合わせと data ステップの pgloader 転送、
#     verify ステップの件数比較のすべてで対象テーブルを除外します（そのデータは
#     移行されません）。.env の MIGRATE_EXCLUDE_TABLES でも指定できます。
#
# 開発/リハーサル用スクリプトのため、docker / podman のどちらでも動きます
# （CONTAINER_CLI で明示指定も可能）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
# .env（非シークレット設定）を読み込みます。SKIP_ENV_FILE=1 のときは読みません
# — `set -a; source` は既に export 済みの値まで上書きしてしまうため、
# 独自の識別子を渡してくる呼び出し元（scripts/test-upgrade.sh）が使います。
if [ -f "${ROOT_DIR}/.env" ] && [ "${SKIP_ENV_FILE:-0}" != "1" ]; then
    # shellcheck disable=SC1091
    set -a; source "${ROOT_DIR}/.env"; set +a
fi

LOG_PREFIX="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [migrate-db]"
log()  { echo "${LOG_PREFIX} $*"; }
warn() { echo "${LOG_PREFIX} WARNING: $*" >&2; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

# ── 設定値 ─────────────────────────────────────────────────────────────────────
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

SECRETS_DIR="${SECRETS_DIR:-${ROOT_DIR}/secrets}"
DB_PASSWORD_FILE="${DB_PASSWORD_FILE:-${SECRETS_DIR}/db_password.txt}"
DB_ROOT_PASSWORD_FILE="${DB_ROOT_PASSWORD_FILE:-${SECRETS_DIR}/db_root_password.txt}"

DB_NAME="${REDMINE_DB_NAME:-redmine}"
DB_USER="${REDMINE_DB_USER:-redmine}"

# 移行元（compose.legacy.yaml）
LEGACY_DB_CONTAINER="${REDMINE_LEGACY_DB_CONTAINER:-redmine-legacy-db}"
LEGACY_WEB_IMAGE="${REDMINE_LEGACY_WEB_IMAGE:-localhost/redmine-web:5.1.1-mysql}"
LEGACY_NETWORK="${REDMINE_LEGACY_NETWORK:-redmine-legacy-net}"
LEGACY_FILES_VOLUME="${REDMINE_LEGACY_FILES_VOLUME:-redmine_legacy_web_files}"
LEGACY_DB_PORT="${REDMINE_LEGACY_DB_PORT:-3306}"

# 移行先（compose.dev.yaml）
PG_DB_CONTAINER="${REDMINE_DB_CONTAINER:-redmine-db}"
PG_NETWORK="${REDMINE_NETWORK:-redmine-net}"
PG_FILES_VOLUME="${REDMINE_FILES_VOLUME:-redmine_web_files}"
PG_DB_PORT="${REDMINE_DB_PORT:-5432}"

PGLOADER_IMAGE="${PGLOADER_IMAGE:-docker.io/dimitri/pgloader:v3.6.7}"
# pgloader (v3.6.7) の MySQL ドライバは caching_sha2_password 非対応のため、
# mysql_native_password の専用ユーザーを一時的に作って使います
# （--no-native-user で無効化。その場合は移行元の DB ユーザーで直接接続します）。
PGLOADER_USER="${PGLOADER_USER:-redmine_pgloader}"

STEPS_DEFAULT="preflight,schema,data,sequences,files,verify"
STEPS="${STEPS_DEFAULT}"
ASSUME_YES=0
NATIVE_USER=1
KEEP_PGLOADER_USER=0
# 既にアンインストール済みのプラグインが残した孤立テーブル（コード無し・
# マイグレーションの痕跡だけ有り）をカンマ区切りで指定します。preflight/schema
# の突き合わせ、pgloader の転送、verify の件数比較のすべてから除外されます。
EXCLUDE_TABLES="${MIGRATE_EXCLUDE_TABLES:-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --steps)
            [ "$#" -ge 2 ] || die "--steps requires an argument"
            STEPS="$2"; shift ;;
        --steps=*) STEPS="${1#--steps=}" ;;
        --yes|-y) ASSUME_YES=1 ;;
        --no-native-user) NATIVE_USER=0 ;;
        --keep-pgloader-user) KEEP_PGLOADER_USER=1 ;;
        --exclude-tables)
            [ "$#" -ge 2 ] || die "--exclude-tables requires an argument"
            EXCLUDE_TABLES="$2"; shift ;;
        --exclude-tables=*) EXCLUDE_TABLES="${1#--exclude-tables=}" ;;
        -h|--help)
            sed -n '2,50p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

has_step() {
    case ",${STEPS}," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

is_excluded_table() {
    case ",${EXCLUDE_TABLES}," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

for s in ${STEPS//,/ }; do
    case "${s}" in
        preflight|schema|data|sequences|files|verify) ;;
        *) die "Unknown step '${s}'. Valid: ${STEPS_DEFAULT}" ;;
    esac
done

cli() { "${CONTAINER_CLI}" "$@"; }

container_running() {
    cli container inspect "$1" --format '{{.State.Status}}' 2>/dev/null | grep -q running
}

# ── 資格情報 ───────────────────────────────────────────────────────────────────
[ -r "${DB_PASSWORD_FILE}" ] || die "DB password file not readable: ${DB_PASSWORD_FILE}"
DB_PASSWORD="$(cat "${DB_PASSWORD_FILE}")"
[ -n "${DB_PASSWORD}" ] || die "DB password file is empty: ${DB_PASSWORD_FILE}"

# MySQL / PostgreSQL への問い合わせヘルパー（いずれもコンテナ内で実行）。
mysql_q() {
    # usage: mysql_q <sql>   -> タブ区切り・ヘッダなしで返す
    cli exec -e MYSQL_PWD="${DB_PASSWORD}" "${LEGACY_DB_CONTAINER}" \
        mysql --protocol=TCP -h 127.0.0.1 -P "${LEGACY_DB_PORT}" \
        -u "${DB_USER}" -D "${DB_NAME}" -N -B -e "$1"
}

mysql_root_q() {
    # usage: mysql_root_q <sql>   -> root 権限が要る操作専用
    cli exec -e MYSQL_PWD="${DB_ROOT_PASSWORD}" "${LEGACY_DB_CONTAINER}" \
        mysql --protocol=TCP -h 127.0.0.1 -P "${LEGACY_DB_PORT}" \
        -u root -N -B -e "$1"
}

psql_q() {
    # usage: psql_q <sql>   -> 値のみ（-tA）
    cli exec -e PGPASSWORD="${DB_PASSWORD}" "${PG_DB_CONTAINER}" \
        psql -h 127.0.0.1 -p "${PG_DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -tAc "$1"
}

# ── 0. 確認 ────────────────────────────────────────────────────────────────────
if has_step data && [ "${ASSUME_YES}" -eq 0 ]; then
    echo ""
    echo "!!! これは破壊的な操作です !!!"
    echo "  移行先 PostgreSQL (${PG_DB_CONTAINER} / DB=${DB_NAME}) の既存データは"
    echo "  truncate され、移行元 MySQL (${LEGACY_DB_CONTAINER}) の内容で置き換えられます。"
    echo ""
    read -r -p "続行するには MIGRATE と入力してください: " confirm
    [ "${confirm}" = "MIGRATE" ] || die "Aborted (confirmation text did not match)."
fi

# ── 1. preflight ───────────────────────────────────────────────────────────────
if has_step preflight; then
    log "[preflight] Checking prerequisites ..."

    container_running "${LEGACY_DB_CONTAINER}" \
        || die "Legacy MySQL container '${LEGACY_DB_CONTAINER}' is not running (compose.legacy.yaml)."
    container_running "${PG_DB_CONTAINER}" \
        || die "Target PostgreSQL container '${PG_DB_CONTAINER}' is not running (compose.dev.yaml)."

    cli image inspect "${LEGACY_WEB_IMAGE}" >/dev/null 2>&1 \
        || die "Legacy web image '${LEGACY_WEB_IMAGE}' not found. Build it with: ${CONTAINER_CLI} compose -f compose.legacy.yaml build"

    mysql_q 'SELECT 1' >/dev/null 2>&1 \
        || die "Cannot query MySQL as '${DB_USER}' (database ${DB_NAME})."
    psql_q 'SELECT 1' >/dev/null 2>&1 \
        || die "Cannot query PostgreSQL as '${DB_USER}' (database ${DB_NAME})."

    SRC_TABLES="$(mysql_q "SELECT table_name FROM information_schema.tables
        WHERE table_schema = '${DB_NAME}' AND table_type = 'BASE TABLE' ORDER BY table_name")"
    [ -n "${SRC_TABLES}" ] || die "Source database '${DB_NAME}' has no tables."
    echo "${SRC_TABLES}" | grep -qx 'issues' \
        || die "Source database does not look like Redmine (no 'issues' table)."

    SRC_MIGRATIONS="$(mysql_q 'SELECT count(*) FROM schema_migrations')"
    log "[preflight] Source: $(echo "${SRC_TABLES}" | wc -l) tables, ${SRC_MIGRATIONS} schema_migrations rows."
    log "[preflight] OK."
fi

# ── 2. schema ──────────────────────────────────────────────────────────────────
if has_step schema; then
    log "[schema] Creating the Rails schema on PostgreSQL with the 5.1.1 image (migrate-only) ..."
    cli run --rm \
        --name redmine-migrate-schema \
        --network "${PG_NETWORK}" \
        -v "${SECRETS_DIR}:/run/secrets:ro" \
        -e REDMINE_DB_ADAPTER=postgresql \
        -e REDMINE_DB_HOST="${PG_DB_CONTAINER}" \
        -e REDMINE_DB_PORT="${PG_DB_PORT}" \
        -e REDMINE_DB_NAME="${DB_NAME}" \
        -e REDMINE_DB_USER="${DB_USER}" \
        -e REDMINE_DB_PASSWORD_FILE=/run/secrets/db_password.txt \
        -e REDMINE_SECRET_KEY_BASE_FILE=/run/secrets/secret_key_base.txt \
        -e REDMINE_PLUGINS_MIGRATE=1 \
        -e REDMINE_LOAD_DEFAULT_DATA=0 \
        -e REDMINE_MIGRATE_ONLY=1 \
        "${LEGACY_WEB_IMAGE}" \
        || die "Schema creation failed (see the output above)."

    # 移行元にあって移行先に無いテーブルがあると pgloader が落ちます。典型的な原因は
    # (a) 移行元にこのイメージが同梱していないプラグインが入っている、または
    # (b) 移行元で過去にアンインストールされたプラグインが、マイグレーションを
    #     ロールバックせずにコード（plugins/ 配下）だけ削除されたため、テーブルが
    #     孤立している、のどちらかです。(b) は --exclude-tables で除外できます。
    SRC_TABLES="$(mysql_q "SELECT table_name FROM information_schema.tables
        WHERE table_schema = '${DB_NAME}' AND table_type = 'BASE TABLE' ORDER BY table_name")"
    DST_TABLES="$(psql_q "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename")"
    MISSING=""
    SKIPPED=""
    while IFS= read -r t; do
        [ -n "${t}" ] || continue
        if echo "${DST_TABLES}" | grep -qx "${t}"; then
            continue
        fi
        if is_excluded_table "${t}"; then
            SKIPPED="${SKIPPED} ${t}"
            continue
        fi
        MISSING="${MISSING} ${t}"
    done <<< "${SRC_TABLES}"
    if [ -n "${SKIPPED}" ]; then
        warn "[schema] Excluding source tables not present on PostgreSQL (--exclude-tables):${SKIPPED}"
        warn "[schema]   Their data will NOT be migrated."
    fi
    if [ -n "${MISSING}" ]; then
        MISSING_CSV="$(echo "${MISSING}" | xargs | tr ' ' ',')"
        die "These source tables do not exist on PostgreSQL:${MISSING}
  移行元に、このイメージが同梱していないプラグインのテーブルがあります。
  次のいずれかで対応してください:
    (a) そのプラグインが移行元でまだ使われているなら、Containerfile.v5-mysql に
        足してイメージを作り直すか、移行元でアンインストールしてから再実行する
    (b) 既にアンインストール済みのプラグインが残した孤立テーブルなら、
        --exclude-tables ${MISSING_CSV} でこのテーブルを除外して再実行する"
    fi
    SCHEMA_DONE_MSG="[schema] Done ($(echo "${SRC_TABLES}" | wc -l) source tables checked"
    if [ -n "${SKIPPED}" ]; then
        SCHEMA_DONE_MSG="${SCHEMA_DONE_MSG}, $(echo "${SKIPPED}" | wc -w) excluded"
    fi
    log "${SCHEMA_DONE_MSG})."
fi

# ── 3. data（pgloader） ────────────────────────────────────────────────────────
if has_step data; then
    PGLOADER_CONN_USER="${DB_USER}"
    PGLOADER_CONN_PASSWORD="${DB_PASSWORD}"

    if [ "${NATIVE_USER}" -eq 1 ]; then
        if [ -r "${DB_ROOT_PASSWORD_FILE}" ]; then
            DB_ROOT_PASSWORD="$(cat "${DB_ROOT_PASSWORD_FILE}")"
            log "[data] Ensuring mysql_native_password user '${PGLOADER_USER}' for pgloader ..."
            # pgloader v3.6.7 は caching_sha2_password を話せません。
            # SELECT だけ持つ一時ユーザーを native password で用意します。
            mysql_root_q "CREATE USER IF NOT EXISTS '${PGLOADER_USER}'@'%'
                    IDENTIFIED WITH mysql_native_password BY '${DB_PASSWORD}';
                ALTER USER '${PGLOADER_USER}'@'%'
                    IDENTIFIED WITH mysql_native_password BY '${DB_PASSWORD}';
                GRANT SELECT, SHOW VIEW, LOCK TABLES ON \`${DB_NAME}\`.* TO '${PGLOADER_USER}'@'%';
                FLUSH PRIVILEGES;" \
                || die "Could not create the pgloader user. Re-run with --no-native-user to skip this."
            PGLOADER_CONN_USER="${PGLOADER_USER}"
        else
            warn "[data] ${DB_ROOT_PASSWORD_FILE} not readable — using '${DB_USER}' for pgloader."
            warn "[data] pgloader fails with 'Unsupported authentication method caching_sha2_password'"
            warn "[data] unless that user authenticates with mysql_native_password."
        fi
    fi

    WORK_DIR="$(mktemp -d)"
    chmod 700 "${WORK_DIR}"
    cleanup_work() { rm -rf "${WORK_DIR}"; }
    trap cleanup_work EXIT

    log "[data] Rendering the pgloader command file ..."
    # schema_migrations/ar_internal_metadata は常に除外（理由はテンプレートの
    # ヘッダコメント参照）。--exclude-tables で指定された孤立テーブルも同様に
    # EXCLUDING 句へ追加します。
    EXCLUDE_TABLES_SQL="'schema_migrations', 'ar_internal_metadata'"
    for t in ${EXCLUDE_TABLES//,/ }; do
        [ -n "${t}" ] || continue
        EXCLUDE_TABLES_SQL="${EXCLUDE_TABLES_SQL}, '${t}'"
    done

    # envsubst に渡す変数名リストなので単一引用符のままで正しい。
    # shellcheck disable=SC2016
    MYSQL_USER="${PGLOADER_CONN_USER}" \
    MYSQL_PASSWORD="${PGLOADER_CONN_PASSWORD}" \
    MYSQL_HOST="${LEGACY_DB_CONTAINER}" \
    MYSQL_PORT="${LEGACY_DB_PORT}" \
    MYSQL_DB="${DB_NAME}" \
    PG_USER="${DB_USER}" \
    PG_PASSWORD="${DB_PASSWORD}" \
    PG_HOST="${PG_DB_CONTAINER}" \
    PG_PORT="${PG_DB_PORT}" \
    PG_DB="${DB_NAME}" \
    EXCLUDE_TABLES_SQL="${EXCLUDE_TABLES_SQL}" \
    envsubst '${MYSQL_USER} ${MYSQL_PASSWORD} ${MYSQL_HOST} ${MYSQL_PORT} ${MYSQL_DB} ${PG_USER} ${PG_PASSWORD} ${PG_HOST} ${PG_PORT} ${PG_DB} ${EXCLUDE_TABLES_SQL}' \
        < "${SCRIPT_DIR}/pgloader/redmine-data-only.load.tmpl" \
        > "${WORK_DIR}/redmine.load"
    chmod 600 "${WORK_DIR}/redmine.load"

    # pgloader は移行元・移行先どちらのネットワークにも参加する必要があります。
    # docker/podman run は 1 つのネットワークしか指定できないため、
    # create → network connect → start の順で 2 本つなぎます。
    cli rm -f redmine-pgloader >/dev/null 2>&1 || true
    log "[data] Running pgloader (data only, truncate) ..."
    cli create --name redmine-pgloader \
        --network "${LEGACY_NETWORK}" \
        -v "${WORK_DIR}:/work:ro" \
        "${PGLOADER_IMAGE}" \
        pgloader --verbose /work/redmine.load >/dev/null \
        || die "Could not create the pgloader container (image ${PGLOADER_IMAGE})."
    cli network connect "${PG_NETWORK}" redmine-pgloader \
        || die "Could not attach the pgloader container to network ${PG_NETWORK}."
    PGLOADER_STATUS=0
    cli start -a redmine-pgloader || PGLOADER_STATUS=$?
    cli rm -f redmine-pgloader >/dev/null 2>&1 || true
    [ "${PGLOADER_STATUS}" -eq 0 ] || die "pgloader failed (exit ${PGLOADER_STATUS})."

    if [ "${NATIVE_USER}" -eq 1 ] && [ "${PGLOADER_CONN_USER}" = "${PGLOADER_USER}" ] \
        && [ "${KEEP_PGLOADER_USER}" -eq 0 ]; then
        log "[data] Dropping the temporary pgloader user ..."
        mysql_root_q "DROP USER IF EXISTS '${PGLOADER_USER}'@'%'; FLUSH PRIVILEGES;" || true
    fi

    cleanup_work
    trap - EXIT
    log "[data] Done."
fi

# ── 4. sequences ───────────────────────────────────────────────────────────────
if has_step sequences; then
    log "[sequences] Resetting serial sequences to max(id) ..."
    cli exec -i -e PGPASSWORD="${DB_PASSWORD}" "${PG_DB_CONTAINER}" \
        psql -h 127.0.0.1 -p "${PG_DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
        -v ON_ERROR_STOP=1 -q -f - < "${SCRIPT_DIR}/pgloader/reset-sequences.sql" \
        || die "Sequence reset failed."
    log "[sequences] Done."
fi

# ── 5. files（添付ファイル） ───────────────────────────────────────────────────
if has_step files; then
    log "[files] Copying attachments volume ${LEGACY_FILES_VOLUME} -> ${PG_FILES_VOLUME} ..."
    # コピーとオーナー設定は redmine イメージの中で行います（redmine ユーザーが
    # 存在するのはイメージの中だけのため）。公式 redmine イメージの uid は
    # 系列間で共通ですが、異なる場合は移行先イメージで chown し直してください。
    cli run --rm \
        -v "${LEGACY_FILES_VOLUME}:/from:ro" \
        -v "${PG_FILES_VOLUME}:/to" \
        --entrypoint /bin/bash \
        "${LEGACY_WEB_IMAGE}" \
        -c 'shopt -s dotglob nullglob; cp -a /from/. /to/ && chown -R redmine:redmine /to' \
        || die "Attachment copy failed."
    log "[files] Done."
fi

# ── 6. verify ──────────────────────────────────────────────────────────────────
if has_step verify; then
    log "[verify] Comparing row counts table by table ..."
    FAILED=0

    SRC_TABLES="$(mysql_q "SELECT table_name FROM information_schema.tables
        WHERE table_schema = '${DB_NAME}' AND table_type = 'BASE TABLE' ORDER BY table_name")"

    while IFS= read -r t; do
        [ -n "${t}" ] || continue
        # --exclude-tables で除外したテーブルは移行先に存在しないため、
        # 件数比較そのものをスキップします（psql が「relation does not exist」で
        # 落ちるのを避けるため、count(*) を投げる前に判定します）。
        if is_excluded_table "${t}"; then
            warn "  SKIP (excluded via --exclude-tables, not migrated) ${t}"
            continue
        fi
        src="$(mysql_q "SELECT count(*) FROM \`${t}\`" | tr -d '[:space:]')"
        dst="$(psql_q "SELECT count(*) FROM \"${t}\"" | tr -d '[:space:]')"
        if [ "${src}" != "${dst}" ]; then
            # schema_migrations / ar_internal_metadata は転送対象外です
            # （移行先は rake db:migrate が作った内容を保持します）。
            case "${t}" in
                schema_migrations|ar_internal_metadata)
                    warn "  DIFF (expected, not copied) ${t}: mysql=${src} postgres=${dst}" ;;
                *)
                    warn "  MISMATCH ${t}: mysql=${src} postgres=${dst}"
                    FAILED=$((FAILED + 1)) ;;
            esac
        fi
    done <<< "${SRC_TABLES}"

    log "[verify] Checking sequences are at or ahead of max(id) ..."
    if ! cli exec -i -e PGPASSWORD="${DB_PASSWORD}" "${PG_DB_CONTAINER}" \
        psql -h 127.0.0.1 -p "${PG_DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
        -v ON_ERROR_STOP=1 -q -f - < "${SCRIPT_DIR}/pgloader/verify-sequences.sql"; then
        warn "  One or more sequences are behind max(id) — re-run the 'sequences' step."
        FAILED=$((FAILED + 1))
    fi

    log "[verify] Checking boolean columns really are boolean ..."
    IS_PRIVATE_TYPE="$(psql_q "SELECT data_type FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'issues' AND column_name = 'is_private'")"
    if [ "${IS_PRIVATE_TYPE}" != "boolean" ]; then
        warn "  issues.is_private is '${IS_PRIVATE_TYPE}', expected 'boolean'."
        FAILED=$((FAILED + 1))
    fi

    log "[verify] Checking the schema_migrations sets match ..."
    SRC_MIG="$(mysql_q 'SELECT count(*) FROM schema_migrations' | tr -d '[:space:]')"
    DST_MIG="$(psql_q 'SELECT count(*) FROM schema_migrations' | tr -d '[:space:]')"
    if [ "${SRC_MIG}" != "${DST_MIG}" ]; then
        if [ -n "${EXCLUDE_TABLES}" ]; then
            # --exclude-tables を使った場合、除外したテーブル分のプラグイン
            # マイグレーションは移行元にしか無いため、この差は想定内です。
            warn "  schema_migrations differ: mysql=${SRC_MIG} postgres=${DST_MIG} (--exclude-tables 使用時は想定内)"
        else
            warn "  schema_migrations differ: mysql=${SRC_MIG} postgres=${DST_MIG}"
            warn "  移行元と移行先で Redmine/プラグイン構成が違う可能性があります。"
            FAILED=$((FAILED + 1))
        fi
    fi

    if [ "${FAILED}" -ne 0 ]; then
        die "[verify] ${FAILED} check(s) failed."
    fi
    log "[verify] All checks passed."
fi

log "Finished (steps: ${STEPS})."
