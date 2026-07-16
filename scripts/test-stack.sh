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
#   - redmine-db actually creates the `redmine` database + PostGIS extensions
#     (regresses if POSTGRES_INITDB_ARGS ever reintroduces --auth-local=peer)
#   - redmine-web's entrypoint doesn't crash-loop (plugin LoadError, or Puma
#     unable to read config/database.yml because of file ownership)
#   - the sub-URI (/redmine) is served by Puma directly, not just via Apache
#     (regresses if config.ru is ever reverted to the stock `run Rails.application`)
#   - both containers report `healthy` and stay up (no restart loop)
#
# This is a destructive test against compose.dev.yaml ONLY: it tears down and
# recreates the redmine-db/redmine-web containers and their named volumes
# (pgdata, redmine_files). It never touches production (quadlets/,
# /opt/redmine). Any existing dev data in those volumes is discarded.
#
# Usage:
#   bash scripts/test-stack.sh            # build, boot, verify, tear down
#   bash scripts/test-stack.sh --keep     # ... and leave the stack running
#   bash scripts/test-stack.sh --skip-build   # reuse existing images (faster iteration)
#
# Runs with podman (podman compose / the podman-compose external provider).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
COMPOSE_FILE="${REPO_ROOT}/compose.dev.yaml"
HOST_PORT="${TEST_STACK_HOST_PORT:-8080}"

KEEP=0
SKIP_BUILD=0
for arg in "$@"; do
    case "${arg}" in
        --keep) KEEP=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "Unknown option: ${arg}" >&2
            exit 2
            ;;
    esac
done

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
        log "  podman compose -f ${COMPOSE_FILE} down -v"
        return
    fi
    log "Tearing down test stack ..."
    podman compose -f "${COMPOSE_FILE}" down -v >/dev/null 2>&1 || true
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
podman compose -f "${COMPOSE_FILE}" config >/dev/null \
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
podman compose -f "${COMPOSE_FILE}" down -v >/dev/null 2>&1 || true
podman rm -f redmine-db redmine-web >/dev/null 2>&1 || true

# ── 3. Build ─────────────────────────────────────────────────────────────────
if [ "${SKIP_BUILD}" -eq 1 ]; then
    log "Skipping build (--skip-build); using existing images."
else
    log "Building redmine-db and redmine-web images ..."
    podman compose -f "${COMPOSE_FILE}" build \
        || die "Image build failed."
fi

log "Checking pg_config is present and on PATH in redmine-web ..."
check "pg_config present on PATH in redmine-web image" \
    podman run --rm --entrypoint sh localhost/redmine-web:6.1.3 -c 'command -v pg_config'

# ── 4. Boot redmine-db and verify database bootstrap ───────────────────────
log "Starting redmine-db ..."
podman compose -f "${COMPOSE_FILE}" up -d --force-recreate redmine-db >/dev/null

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
        "SELECT 1 FROM pg_database WHERE datname = 'redmine'" 2>/dev/null | grep -q '^1$'
}
check "redmine-db created the 'redmine' database" db_exists

extension_installed() {
    local ext="$1"
    podman exec -e PGPASSWORD="${DB_PASSWORD}" redmine-db \
        psql -h 127.0.0.1 -U redmine -d redmine -tAc \
        "SELECT 1 FROM pg_extension WHERE extname = '${ext}'" 2>/dev/null | grep -q '^1$'
}
check "postgis extension installed in 'redmine' db" extension_installed postgis
check "postgis_topology extension installed in 'redmine' db" extension_installed postgis_topology

# ── 5. Boot redmine-web and verify the app actually serves the sub-URI ─────
log "Starting redmine-web ..."
podman compose -f "${COMPOSE_FILE}" up -d --force-recreate redmine-web >/dev/null

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

puma_direct_200() {
    podman exec redmine-web curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/redmine/login \
        | grep -q '^200$'
}
check "login page reachable directly on Puma :3000 (sub-URI mounted in config.ru)" \
    puma_direct_200

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
