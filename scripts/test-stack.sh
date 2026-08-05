#!/bin/bash
# scripts/test-stack.sh
#
# Integration test for the redmine Redmine stack (development / Docker Compose
# path). Builds both images fresh and boots them with compose.dev.yaml,
# reproducing every check that has, in practice, caught a real boot-time bug
# in this stack:
#
#   - compose.dev.yaml parses (`podman compose config`)
#   - both images build (plugin clones + `bundle install` + webpack)
#   - pg_config is present and on PATH inside the redmine-web image
#   - redmine-db actually creates the test database + PostGIS extensions
#     (regresses if POSTGRES_INITDB_ARGS ever reintroduces --auth-local=peer)
#   - redmine-web's entrypoint doesn't crash-loop (plugin LoadError, or Puma
#     unable to read config/database.yml because of file ownership)
#   - the sub-URI (/redmine) is served by Puma directly, not just via Apache
#     (regresses if config.ru is ever reverted to the stock `run Rails.application`)
#   - both containers report `healthy` and stay up (no restart loop)
#
# The app server under test is selected with --web-server (REDMINE_WEB_SERVER):
#   puma      (default) Apache -> ProxyPass -> Puma :3000
#   passenger           Apache + mod_passenger, no Puma and no :3000
# The two modes share one image, so a full run of both is:
#   bash scripts/test-stack.sh
#   bash scripts/test-stack.sh --web-server passenger --skip-build
#
# The Redmine series under test is selected with --series (5 / 6 / 7, default 6).
# Each series has its own Containerfile, base image and plugin set, so the flag
# sets REDMINE_WEB_CONTAINERFILE / REDMINE_WEB_BASE_IMAGE / REDMINE_WEB_IMAGE
# together (same triples as the .env.example presets):
#   5 -> Containerfile.v5 / redmine:5.1.12
#   6 -> Containerfile.v6 / redmine:6.1.3   (default)
#   7 -> Containerfile.v7 / redmine:7.0.0
# Series images have different tags, so --skip-build only reuses an image built
# for that same series. With --series 7 --web-server passenger there is one
# extra check: the Redmine 7 base is Ruby 4.0 and Passenger only supports it
# from 6.1.1, so Containerfile.v7 pulls mod_passenger from Debian forky and the
# test asserts the running container really has 6.1 or newer.
#
# This is a destructive test against compose.dev.yaml ONLY: it tears down and
# recreates the redmine-db/redmine-web containers under a dedicated compose
# project (redmine_test) with their own dedicated named volumes
# (redmine_test_pgdata, redmine_test_web_files — see REDMINE_DB_VOLUME /
# REDMINE_FILES_VOLUME overrides below). It never touches production
# (quadlets/, /opt/redmine) or a real dev stack's data.
#
# Both the Postgres database name (REDMINE_DB_NAME=redmine_test by default,
# see TEST_DB_NAME below) AND the underlying volumes are isolated from the
# "redmine"-named dev/production database and its "redmine_pgdata"/
# "redmine_web_files" volumes — compose.dev.yaml pins volumes to fixed
# external names via `name:`, which are NOT project-namespaced, so without
# this override a test run would silently attach to (and tear down) whatever
# volume a real dev stack on the same host already created.
#
# Usage:
#   bash scripts/test-stack.sh            # build, boot, verify, tear down
#   bash scripts/test-stack.sh --keep     # ... and leave the stack running
#   bash scripts/test-stack.sh --skip-build   # reuse existing images (faster iteration)
#   bash scripts/test-stack.sh --web-server passenger   # test the Passenger mode
#   bash scripts/test-stack.sh --series 7 # test the Redmine 7 image (5 / 6 / 7)
#
# Runs with podman (podman compose / the podman-compose external provider).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
COMPOSE_FILE="${REPO_ROOT}/compose.dev.yaml"
HOST_PORT="${TEST_STACK_HOST_PORT:-8080}"
TEST_DB_NAME="${TEST_STACK_DB_NAME:-redmine_test}"
export REDMINE_DB_NAME="${TEST_DB_NAME}"
# compose.dev.yaml pins its volumes to fixed external names via `name:`
# (REDMINE_DB_VOLUME/REDMINE_FILES_VOLUME), which are NOT project-namespaced —
# so without overriding them here, a test run would silently attach to
# whatever "redmine_pgdata"/"redmine_web_files" volume a real dev stack on
# this host already created (possibly with a differently-named database
# already initialized inside it), rather than getting its own fresh volume.
export REDMINE_DB_VOLUME="${TEST_STACK_DB_VOLUME:-redmine_test_pgdata}"
export REDMINE_FILES_VOLUME="${TEST_STACK_FILES_VOLUME:-redmine_test_web_files}"
# Pin the compose project name explicitly: this podman-compose install
# mis-resolves the implicit project name on `up` (observed producing the
# invalid volume name "_-redmine_pgdata" and failing outright), and pinning
# it also gives the test run volumes fully separate from any real dev stack.
PROJECT_NAME="${TEST_STACK_PROJECT_NAME:-redmine_test}"
pc() { podman compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" "$@"; }

KEEP=0
SKIP_BUILD=0
WEB_SERVER="${TEST_STACK_WEB_SERVER:-puma}"
SERIES="${TEST_STACK_SERIES:-6}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        --web-server)
            [ "$#" -ge 2 ] || { echo "--web-server requires an argument" >&2; exit 2; }
            WEB_SERVER="$2"
            shift
            ;;
        --web-server=*) WEB_SERVER="${1#--web-server=}" ;;
        --series)
            [ "$#" -ge 2 ] || { echo "--series requires an argument" >&2; exit 2; }
            SERIES="$2"
            shift
            ;;
        --series=*) SERIES="${1#--series=}" ;;
        -h|--help)
            sed -n '2,61p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
    shift
done

case "${WEB_SERVER}" in
    puma|passenger) ;;
    *) echo "--web-server must be 'puma' or 'passenger' (got '${WEB_SERVER}')" >&2; exit 2 ;;
esac

# Redmine のメジャーバージョン系列。系列ごとに Containerfile とベースイメージが
# 違うため、compose.dev.yaml が読む 3 つの変数をここでまとめて設定します
# （.env.example のプリセットと同じ組み合わせ）。--skip-build で使い回す
# イメージタグもここで決まります。
case "${SERIES}" in
    5) REDMINE_SERIES_VERSION=5.1.12; REDMINE_SERIES_CONTAINERFILE=Containerfile.v5 ;;
    6) REDMINE_SERIES_VERSION=6.1.3;  REDMINE_SERIES_CONTAINERFILE=Containerfile.v6 ;;
    7) REDMINE_SERIES_VERSION=7.0.0;  REDMINE_SERIES_CONTAINERFILE=Containerfile.v7 ;;
    *) echo "--series must be '5', '6' or '7' (got '${SERIES}')" >&2; exit 2 ;;
esac
export REDMINE_WEB_CONTAINERFILE="${REDMINE_SERIES_CONTAINERFILE}"
export REDMINE_WEB_BASE_IMAGE="docker.io/library/redmine:${REDMINE_SERIES_VERSION}"
export REDMINE_WEB_IMAGE="localhost/redmine-web:${REDMINE_SERIES_VERSION}"
# redmine-web の entrypoint / healthcheck が読む値。compose.dev.yaml の
# `REDMINE_WEB_SERVER: ${REDMINE_WEB_SERVER:-puma}` 経由でコンテナへ渡ります。
export REDMINE_WEB_SERVER="${WEB_SERVER}"

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [test-stack] $*"; }
warn() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [test-stack] WARNING: $*" >&2; }
die()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [test-stack] ERROR: $*" >&2; exit 1; }

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

cd "${REPO_ROOT}"

cleanup() {
    if [ "${KEEP}" -eq 1 ]; then
        log "Leaving the stack running (--keep). Tear down later with:"
        log "  podman compose -p ${PROJECT_NAME} -f ${COMPOSE_FILE} down -v"
        return
    fi
    log "Tearing down test stack ..."
    pc down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── 0. Prerequisites ────────────────────────────────────────────────────────
command -v podman >/dev/null 2>&1 || die "podman is not installed."

if [ ! -r "${REPO_ROOT}/secrets/db_password.txt" ] || [ ! -r "${REPO_ROOT}/secrets/secret_key_base.txt" ]; then
    log "Secrets missing — generating (bash scripts/generate-secrets.sh) ..."
    bash "${SCRIPT_DIR}/generate-secrets.sh"
fi

# ── 1. Static checks ────────────────────────────────────────────────────────
log "Validating compose.dev.yaml syntax ..."
pc config >/dev/null \
    || die "compose.dev.yaml failed to parse. Fix syntax before continuing."

if command -v shellcheck >/dev/null 2>&1; then
    log "Running shellcheck on scripts/*.sh and containers/**/*.sh ..."
    # shellcheck disable=SC2046
    check "shellcheck passes" shellcheck "${SCRIPT_DIR}"/*.sh $(find "${REPO_ROOT}/containers" -name '*.sh')
else
    warn "shellcheck not installed — skipping lint check."
fi

# ── 2. Clear residue: previous test/dev containers and volumes ─────────────
log "Clearing any residue from a previous run ..."
pc down -v >/dev/null 2>&1 || true
podman rm -f redmine-db redmine-web >/dev/null 2>&1 || true

# ── 3. Build ─────────────────────────────────────────────────────────────────
if [ "${SKIP_BUILD}" -eq 1 ]; then
    log "Skipping build (--skip-build); using existing images."
else
    log "Building redmine-db and redmine-web images ..."
    pc build \
        || die "Image build failed."
fi

log "Checking pg_config is present and on PATH in redmine-web ..."
check "pg_config present on PATH in redmine-web image" \
    podman run --rm --entrypoint sh "${REDMINE_WEB_IMAGE}" -c 'command -v pg_config'

# ── 4. Boot redmine-db and verify database bootstrap ───────────────────────
log "Starting redmine-db ..."
pc up -d --force-recreate redmine-db >/dev/null

wait_healthy() {
    local name="$1" timeout="$2" waited=0 status
    while true; do
        status="$(podman inspect --format '{{.State.Health.Status}}' "${name}" 2>/dev/null || echo unknown)"
        case "${status}" in
            healthy) return 0 ;;
            unhealthy) warn "${name} reported unhealthy"; return 1 ;;
        esac
        if [ "${waited}" -ge "${timeout}" ]; then
            warn "Timed out after ${timeout}s waiting for ${name} to become healthy (last status: ${status})"
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

check "redmine-db becomes healthy" wait_healthy redmine-db 120

DB_PASSWORD="$(cat "${REPO_ROOT}/secrets/db_password.txt")"

logs_lack() {
    local container="$1" pattern="$2"
    ! podman logs "${container}" 2>&1 | grep -qF "${pattern}"
}
check "redmine-db logs have no 'Peer authentication failed'" \
    logs_lack redmine-db "Peer authentication failed"

db_exists() {
    podman exec -e PGPASSWORD="${DB_PASSWORD}" redmine-db \
        psql -h 127.0.0.1 -U redmine -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname = '${TEST_DB_NAME}'" 2>/dev/null | grep -q '^1$'
}
check "redmine-db created the '${TEST_DB_NAME}' database" db_exists

extension_installed() {
    local ext="$1"
    podman exec -e PGPASSWORD="${DB_PASSWORD}" redmine-db \
        psql -h 127.0.0.1 -U redmine -d "${TEST_DB_NAME}" -tAc \
        "SELECT 1 FROM pg_extension WHERE extname = '${ext}'" 2>/dev/null | grep -q '^1$'
}
check "postgis extension installed in '${TEST_DB_NAME}' db" extension_installed postgis
check "postgis_topology extension installed in '${TEST_DB_NAME}' db" extension_installed postgis_topology

# ── 5. Boot redmine-web and verify the app actually serves the sub-URI ─────
log "Starting redmine-web (Redmine ${SERIES} 系 / ${REDMINE_WEB_IMAGE}, REDMINE_WEB_SERVER=${WEB_SERVER}) ..."
pc up -d --force-recreate redmine-web >/dev/null

check "redmine-web becomes healthy" wait_healthy redmine-web 400

check "redmine-web logs have no plugin LoadError" \
    logs_lack redmine-web "LoadError"
check "redmine-web logs have no config file Permission denied" \
    logs_lack redmine-web "Permission denied"
check "redmine-web logs have no sub-URI routing error" \
    logs_lack redmine-web 'No route matches'

restart_count_zero() {
    [ "$(podman inspect --format '{{.RestartCount}}' redmine-web 2>/dev/null)" = "0" ]
}
check "redmine-web did not restart/crash-loop" restart_count_zero

http_200() {
    local url="$1"
    [ "$(curl -sS -o /dev/null -w '%{http_code}' "${url}")" = "200" ]
}
check "login page reachable via Apache (:${HOST_PORT})" \
    http_200 "http://localhost:${HOST_PORT}/redmine/login"

if [ "${WEB_SERVER}" = "puma" ]; then
    puma_direct_200() {
        podman exec redmine-web curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/redmine/login \
            | grep -q '^200$'
    }
    check "login page reachable directly on Puma :3000 (sub-URI mounted in config.ru)" \
        puma_direct_200
else
    # Passenger モードでは Puma を起動しないので :3000 は listen していないこと、
    # そのぶん mod_passenger が実際に読み込まれていることを確認します。
    puma_absent() {
        ! podman exec redmine-web curl -sS -o /dev/null --max-time 5 \
            http://127.0.0.1:3000/redmine/login 2>/dev/null
    }
    check "no Puma listening on :3000 (Passenger mode)" puma_absent

    passenger_module_loaded() {
        podman exec redmine-web apache2ctl -M 2>/dev/null | grep -q 'passenger_module'
    }
    check "mod_passenger is loaded in Apache" passenger_module_loaded

    if [ "${SERIES}" = "7" ]; then
        # 7 系のベースは Ruby 4.0 で、Passenger の Ruby 4 対応は 6.1.1 以降です。
        # Containerfile.v7 は forky から 6.1.x を pin 導入しているので、
        # 実際に走っているコンテナでもバージョンを確認します。
        passenger_supports_ruby4() {
            local version
            version="$(podman exec redmine-web \
                dpkg-query -W -f='${Version}' libapache2-mod-passenger 2>/dev/null)" || return 1
            podman exec redmine-web dpkg --compare-versions "${version}" ge 6.1
        }
        check "mod_passenger is 6.1+ (Ruby 4 support, from forky)" \
            passenger_supports_ruby4
    fi

    passenger_static_200() {
        # Apache が public/ を Alias 経由で配信できていること（<Directory> 許可漏れ検知）。
        # 対象は public/404.html です。Redmine 6.0 でスタイルシートが
        # public/stylesheets/ から app/assets/stylesheets/ へ移動し、6.1 / 7.0 の
        # public/ には 404.html / 500.html / plugin_assets しか無くなったため、
        # stylesheets/application.css は 5 系でしか存在しません。
        # 404.html は 5.1 / 6.1 / 7.0 のすべてに存在します。
        http_200 "http://localhost:${HOST_PORT}/redmine/404.html"
    }
    check "static asset served by Apache from public/ (Alias + <Directory>)" \
        passenger_static_200
fi

check "podman healthcheck run redmine-web exits 0" \
    podman healthcheck run redmine-web

# ── Summary ──────────────────────────────────────────────────────────────────
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
