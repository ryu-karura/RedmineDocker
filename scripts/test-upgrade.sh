#!/bin/bash
# scripts/test-upgrade.sh
#
# 「Redmine 5.1.6 + MySQL 8.0 → PostgreSQL 18 へコンバート → Redmine 7.0.0 へ
# アップグレード」の一連の手順を、実データを入れた状態で通しで検証します。
# 手順そのものの説明は docs/Upgrade.md にあります。このスクリプトはその手順を
# 自動化し、各段の結果を検査するものです。
#
# 検証する内容:
#   1. 移行元スタックが構築・起動できる（Redmine 5.1.6 / MySQL 8.0 / 10 plugins）
#   2. 検証用データ（プロジェクト・チケット・Wiki・ユーザー、日本語と boolean を含む）
#      を投入できる
#   3. scripts/migrate-mysql-to-postgres.sh で PostgreSQL 18 へコンバートできる
#      （件数一致・シーケンス・boolean 型まで検証）
#   4. コンバート後の DB に対し 5.1.6 のまま Redmine が起動し、データが見える
#   5. Redmine 7 に無いプラグイン（redmine_banner）をアンインストールできる
#   6. Redmine 7.0.0 イメージへ差し替えて起動でき、マイグレーションが通り、
#      データが保持されている
#
# ★ 破壊的です。専用のプロジェクト名・ボリューム・DB 名を使うため通常の開発/本番
#   スタックには触れませんが、前回の実行結果は毎回作り直します。
#
# 使い方:
#   bash scripts/test-upgrade.sh              # 通しで実行し、最後に片付ける
#   bash scripts/test-upgrade.sh --keep       # 片付けずに残す（調査用）
#   bash scripts/test-upgrade.sh --skip-build # 既存イメージを再利用（再実行が速い）
#
# 所要時間の目安: イメージビルドを含めて 30〜60 分（初回）。
# docker / podman のどちらでも動きます（CONTAINER_CLI で明示指定も可能）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

KEEP=0
SKIP_BUILD=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

CONTAINER_CLI="${CONTAINER_CLI:-}"
if [ -z "${CONTAINER_CLI}" ]; then
    if command -v docker >/dev/null 2>&1; then
        CONTAINER_CLI=docker
    elif command -v podman >/dev/null 2>&1; then
        CONTAINER_CLI=podman
    else
        echo "Neither docker nor podman found." >&2; exit 1
    fi
fi

# ── テスト専用の識別子（通常の開発/本番スタックと衝突させない） ───────────────
export REDMINE_DB_NAME="${TEST_UPGRADE_DB_NAME:-redmine_upgrade_test}"
export REDMINE_DB_USER="${TEST_UPGRADE_DB_USER:-redmine}"

# 移行元（compose.legacy.yaml）
LEGACY_PROJECT="redmine_upgrade_legacy"
export REDMINE_LEGACY_NETWORK="redmine_upgrade_legacy_net"
export REDMINE_LEGACY_DB_CONTAINER="redmine-upgrade-legacy-db"
export REDMINE_LEGACY_WEB_CONTAINER="redmine-upgrade-legacy-web"
export REDMINE_LEGACY_DB_VOLUME="redmine_upgrade_legacy_mysqldata"
export REDMINE_LEGACY_FILES_VOLUME="redmine_upgrade_legacy_files"
export REDMINE_LEGACY_WEB_HOST_PORT="${TEST_UPGRADE_LEGACY_PORT:-8081}"

# 移行先（compose.dev.yaml、Redmine 7 系）
TARGET_PROJECT="redmine_upgrade_target"
export REDMINE_NETWORK="redmine_upgrade_target_net"
export REDMINE_DB_CONTAINER="redmine-upgrade-db"
export REDMINE_WEB_CONTAINER="redmine-upgrade-web"
export REDMINE_DB_VOLUME="redmine_upgrade_pgdata"
export REDMINE_FILES_VOLUME="redmine_upgrade_web_files"
export REDMINE_WEB_HOST_PORT="${TEST_UPGRADE_TARGET_PORT:-8082}"
export REDMINE_WEB_CONTAINERFILE="Containerfile.v7"
export REDMINE_WEB_BASE_IMAGE="docker.io/library/redmine:7.0.0"
export REDMINE_WEB_IMAGE="localhost/redmine-web:7.0.0"

# コンバート後の 5.1.6 動作確認に使う単発コンテナ
ON_PG_CONTAINER="redmine-upgrade-legacy-on-pg"
ON_PG_PORT="${TEST_UPGRADE_ON_PG_PORT:-8083}"
LEGACY_WEB_IMAGE="${REDMINE_LEGACY_WEB_IMAGE:-localhost/redmine-web:5.1.6-mysql}"

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [test-upgrade] $*"; }
warn() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [test-upgrade] WARNING: $*" >&2; }
die()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [test-upgrade] ERROR: $*" >&2; exit 1; }

FAILURES=()
check() {
    local desc="$1"; shift
    if "$@"; then
        log "  OK   - ${desc}"
    else
        warn "  FAIL - ${desc}"
        FAILURES+=("${desc}")
    fi
}

cli() { "${CONTAINER_CLI}" "$@"; }
legacy_compose() { cli compose -p "${LEGACY_PROJECT}" -f compose.legacy.yaml "$@"; }
target_compose() { cli compose -p "${TARGET_PROJECT}" -f compose.dev.yaml "$@"; }

cleanup() {
    cli rm -f "${ON_PG_CONTAINER}" >/dev/null 2>&1 || true
    if [ "${KEEP}" -eq 1 ]; then
        log "Leaving both stacks running (--keep). Tear down later with:"
        log "  ${CONTAINER_CLI} compose -p ${LEGACY_PROJECT} -f compose.legacy.yaml down -v"
        log "  ${CONTAINER_CLI} compose -p ${TARGET_PROJECT} -f compose.dev.yaml down -v"
        return
    fi
    log "Tearing down ..."
    legacy_compose down -v >/dev/null 2>&1 || true
    target_compose down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_healthy() {
    local name="$1" timeout="$2" waited=0 status
    while true; do
        status="$(cli inspect --format '{{.State.Health.Status}}' "${name}" 2>/dev/null || echo unknown)"
        case "${status}" in
            healthy) return 0 ;;
            unhealthy) warn "${name} reported unhealthy"; return 1 ;;
        esac
        if [ "${waited}" -ge "${timeout}" ]; then
            warn "Timed out after ${timeout}s waiting for ${name} (last status: ${status})"
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

http_200() { [ "$(curl -sS -o /dev/null -w '%{http_code}' "$1")" = "200" ]; }

# rails runner をコンテナ内で実行し、標準出力をそのまま返します。
runner() {
    local container="$1" ruby="$2"
    cli exec -i "${container}" bundle exec rails runner -e production - <<<"${ruby}"
}

runner_equals() {
    local container="$1" ruby="$2" expected="$3" actual
    actual="$(runner "${container}" "${ruby}" | tr -d '\r' | tail -n1 | tr -d '[:space:]')"
    if [ "${actual}" = "${expected}" ]; then
        return 0
    fi
    warn "    expected '${expected}', got '${actual}'"
    return 1
}

# ── 0. 前提 ────────────────────────────────────────────────────────────────────
if [ ! -r secrets/db_password.txt ] || [ ! -r secrets/secret_key_base.txt ] \
    || [ ! -r secrets/db_root_password.txt ]; then
    log "Secrets missing — generating (bash scripts/generate-secrets.sh) ..."
    bash "${SCRIPT_DIR}/generate-secrets.sh"
fi

log "Clearing residue from a previous run ..."
legacy_compose down -v >/dev/null 2>&1 || true
target_compose down -v >/dev/null 2>&1 || true
cli rm -f "${ON_PG_CONTAINER}" >/dev/null 2>&1 || true

# ── 1. 移行元スタック（Redmine 5.1.6 + MySQL 8.0） ─────────────────────────────
if [ "${SKIP_BUILD}" -eq 0 ]; then
    log "Building the legacy stack images (Redmine 5.1.6 + MySQL 8.0) ..."
    legacy_compose build || die "Legacy image build failed."
fi

log "Starting the legacy stack ..."
legacy_compose up -d >/dev/null || die "Legacy stack failed to start."

check "legacy MySQL becomes healthy"  wait_healthy "${REDMINE_LEGACY_DB_CONTAINER}" 180
check "legacy Redmine becomes healthy" wait_healthy "${REDMINE_LEGACY_WEB_CONTAINER}" 600
check "legacy login page is served (:${REDMINE_LEGACY_WEB_HOST_PORT})" \
    http_200 "http://localhost:${REDMINE_LEGACY_WEB_HOST_PORT}/redmine/login"
check "legacy Redmine reports version 5.1.6" \
    runner_equals "${REDMINE_LEGACY_WEB_CONTAINER}" 'puts Redmine::VERSION.to_s' "5.1.6"
check "legacy Redmine loaded 10 plugins" \
    runner_equals "${REDMINE_LEGACY_WEB_CONTAINER}" 'puts Redmine::Plugin.all.size' "10"
check "legacy Redmine is on the mysql2 adapter" \
    runner_equals "${REDMINE_LEGACY_WEB_CONTAINER}" \
        'puts ActiveRecord::Base.connection.adapter_name.downcase' "mysql2"

# ── 2. 検証用データ投入 ────────────────────────────────────────────────────────
log "Seeding rehearsal data into the legacy stack ..."
SEED_RUBY=$(cat <<'RUBY'
admin = User.find_by(login: "admin") || User.first
unless Project.find_by(identifier: "upgrade-rehearsal")
  project = Project.create!(name: "アップグレード検証", identifier: "upgrade-rehearsal",
                            description: "MySQL → PostgreSQL → Redmine 7 の検証用")
  project.enabled_module_names = %w[issue_tracking wiki]

  user = User.new(login: "rehearsal", firstname: "検証", lastname: "ユーザー",
                  mail: "rehearsal@example.com", language: "ja")
  user.password = user.password_confirmation = "Rehearsal12345!"
  user.save!

  # is_private = true は MySQL では tinyint(1)、PostgreSQL では boolean。
  # コンバートで型変換が正しく行われたかを確認するための種データです。
  Issue.create!(project: project, tracker: Tracker.first, author: admin,
                subject: "検証用チケット ①", description: "日本語 & boolean の検証",
                status: IssueStatus.first,
                priority: IssuePriority.default || IssuePriority.first,
                is_private: true)
  Issue.create!(project: project, tracker: Tracker.first, author: admin,
                subject: "検証用チケット ②", description: "2 件目",
                status: IssueStatus.first,
                priority: IssuePriority.default || IssuePriority.first,
                is_private: false)

  wiki = project.wiki || Wiki.create!(project: project, start_page: "Wiki")
  page = WikiPage.new(wiki: wiki, title: "Rehearsal")
  page.content = WikiContent.new(text: "日本語のウィキ本文\n", author: admin)
  page.save!
end
puts Issue.count
RUBY
)
check "seed data created (2 issues)" \
    runner_equals "${REDMINE_LEGACY_WEB_CONTAINER}" "${SEED_RUBY}" "2"
check "seed data has one private issue" \
    runner_equals "${REDMINE_LEGACY_WEB_CONTAINER}" 'puts Issue.where(is_private: true).count' "1"

# ── 3. 移行先 DB（PostgreSQL 18 + PostGIS 3.6）を起動 ──────────────────────────
if [ "${SKIP_BUILD}" -eq 0 ]; then
    log "Building the target PostgreSQL image ..."
    target_compose build redmine-db || die "Target DB image build failed."
fi
log "Starting the target PostgreSQL ..."
target_compose up -d redmine-db >/dev/null || die "Target DB failed to start."
check "target PostgreSQL becomes healthy" wait_healthy "${REDMINE_DB_CONTAINER}" 180

# ── 4. コンバート ──────────────────────────────────────────────────────────────
log "Running scripts/migrate-mysql-to-postgres.sh ..."
# SKIP_ENV_FILE=1: ここで export したテスト専用の識別子を .env に上書きさせない。
if SKIP_ENV_FILE=1 bash "${SCRIPT_DIR}/migrate-mysql-to-postgres.sh" --yes; then
    log "  OK   - MySQL -> PostgreSQL conversion (incl. its own verify step)"
else
    warn "  FAIL - MySQL -> PostgreSQL conversion"
    FAILURES+=("MySQL -> PostgreSQL conversion")
fi

# ── 5. コンバート後の DB に対して 5.1.6 が動くか ───────────────────────────────
log "Booting Redmine 5.1.6 against the converted PostgreSQL database ..."
cli run -d --name "${ON_PG_CONTAINER}" \
    --network "${REDMINE_NETWORK}" \
    -p "127.0.0.1:${ON_PG_PORT}:80" \
    -v "$(pwd)/secrets:/run/secrets:ro" \
    -e RAILS_ENV=production \
    -e RAILS_RELATIVE_URL_ROOT=/redmine \
    -e REDMINE_WEB_SERVER=puma \
    -e REDMINE_DB_ADAPTER=postgresql \
    -e REDMINE_DB_HOST="${REDMINE_DB_CONTAINER}" \
    -e REDMINE_DB_NAME="${REDMINE_DB_NAME}" \
    -e REDMINE_DB_USER="${REDMINE_DB_USER}" \
    -e REDMINE_DB_PASSWORD_FILE=/run/secrets/db_password.txt \
    -e REDMINE_SECRET_KEY_BASE_FILE=/run/secrets/secret_key_base.txt \
    -e REDMINE_LOAD_DEFAULT_DATA=0 \
    "${LEGACY_WEB_IMAGE}" >/dev/null \
    || die "Could not start Redmine 5.1.6 against PostgreSQL."

check "5.1.6-on-PostgreSQL becomes healthy" wait_healthy "${ON_PG_CONTAINER}" 600
check "5.1.6-on-PostgreSQL serves the login page" \
    http_200 "http://localhost:${ON_PG_PORT}/redmine/login"
check "5.1.6-on-PostgreSQL is on the postgresql adapter" \
    runner_equals "${ON_PG_CONTAINER}" \
        'puts ActiveRecord::Base.connection.adapter_name.downcase' "postgresql"
check "migrated data is visible (2 issues)" \
    runner_equals "${ON_PG_CONTAINER}" 'puts Issue.count' "2"
check "boolean survived the conversion (1 private issue)" \
    runner_equals "${ON_PG_CONTAINER}" 'puts Issue.where(is_private: true).count' "1"
check "multibyte text survived the conversion" \
    runner_equals "${ON_PG_CONTAINER}" \
        'puts Issue.where(subject: "検証用チケット ①").count' "1"
check "sequences work (a new issue can be created)" \
    runner_equals "${ON_PG_CONTAINER}" \
        'i = Issue.new(project: Project.find_by(identifier: "upgrade-rehearsal"), tracker: Tracker.first, author: User.first, subject: "シーケンス検証", status: IssueStatus.first, priority: IssuePriority.default || IssuePriority.first); i.save!; puts Issue.count' \
        "3"

# ── 6. Redmine 7 に無いプラグインのアンインストール ───────────────────────────
log "Uninstalling redmine_banner (not shipped in the Redmine 7 image) ..."
if cli exec "${ON_PG_CONTAINER}" \
    bundle exec rake redmine:plugins:migrate NAME=redmine_banner VERSION=0 RAILS_ENV=production; then
    log "  OK   - redmine_banner migrations rolled back"
else
    warn "  FAIL - redmine_banner rollback"
    FAILURES+=("redmine_banner rollback")
fi
cli rm -f "${ON_PG_CONTAINER}" >/dev/null 2>&1 || true

# ── 7. Redmine 7.0.0 へアップグレード ──────────────────────────────────────────
if [ "${SKIP_BUILD}" -eq 0 ]; then
    log "Building the Redmine 7.0.0 image ..."
    target_compose build redmine-web || die "Redmine 7 image build failed."
fi
log "Starting Redmine 7.0.0 against the converted database (runs the 5.1 -> 7.0 migrations) ..."
target_compose up -d redmine-web >/dev/null || die "Redmine 7 failed to start."

check "Redmine 7 becomes healthy" wait_healthy "${REDMINE_WEB_CONTAINER}" 900
check "Redmine 7 serves the login page (:${REDMINE_WEB_HOST_PORT})" \
    http_200 "http://localhost:${REDMINE_WEB_HOST_PORT}/redmine/login"
check "Redmine reports version 7.0.0" \
    runner_equals "${REDMINE_WEB_CONTAINER}" 'puts Redmine::VERSION.to_s' "7.0.0"
check "Redmine 7 is on the postgis adapter" \
    runner_equals "${REDMINE_WEB_CONTAINER}" \
        'puts ActiveRecord::Base.connection.adapter_name.downcase' "postgis"
check "all core migrations are applied" \
    runner_equals "${REDMINE_WEB_CONTAINER}" \
        'ctx = ActiveRecord::Base.connection_pool.respond_to?(:migration_context) ? ActiveRecord::Base.connection_pool.migration_context : ActiveRecord::Base.connection.migration_context; puts ctx.needs_migration? ? "pending" : "none"' \
        "none"
check "data survived the upgrade (3 issues)" \
    runner_equals "${REDMINE_WEB_CONTAINER}" 'puts Issue.count' "3"
check "private issue flag survived the upgrade" \
    runner_equals "${REDMINE_WEB_CONTAINER}" 'puts Issue.where(is_private: true).count' "1"
check "wiki page survived the upgrade" \
    runner_equals "${REDMINE_WEB_CONTAINER}" 'puts WikiPage.where(title: "Rehearsal").count' "1"
check "rehearsal user survived the upgrade" \
    runner_equals "${REDMINE_WEB_CONTAINER}" 'puts User.where(login: "rehearsal").count' "1"
restart_count_zero() {
    [ "$(cli inspect --format '{{.RestartCount}}' "$1" 2>/dev/null)" = "0" ]
}
check "no crash loop on the Redmine 7 container" \
    restart_count_zero "${REDMINE_WEB_CONTAINER}"

# ── まとめ ─────────────────────────────────────────────────────────────────────
echo ""
if [ "${#FAILURES[@]}" -eq 0 ]; then
    log "All checks passed."
    exit 0
else
    warn "${#FAILURES[@]} check(s) failed:"
    for f in "${FAILURES[@]}"; do
        warn "  - ${f}"
    done
    exit 1
fi
