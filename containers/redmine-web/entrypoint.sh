#!/bin/bash
# containers/redmine-web/entrypoint.sh
#
# Entrypoint for the redmine-web container (Redmine 6.1.3, official image +
# plugin stack). Runs as root so Apache can bind to TCP :80, while Puma is
# started as the unprivileged `redmine` user.
#
# Sequence:
#   1. Resolve secrets (supports Docker/Podman *_FILE indirection)
#   2. Render config/database.yml (postgis adapter) and config/configuration.yml
#   3. Wait for PostgreSQL to accept connections
#   4. Run core + plugin database migrations (idempotent; gated by
#      REDMINE_NO_DB_MIGRATE / REDMINE_PLUGINS_MIGRATE, per the official image)
#   5. Start Apache on TCP :80 and launch Puma via `rails server` on TCP :3000
#      (sub-URI /redmine)
#
# Passwords are never baked into the image or passed as plain env in production;
# they arrive as secret files referenced by *_FILE variables.

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
# Migration switches mirror the official redmine image's docker-entrypoint.sh:
#   REDMINE_NO_DB_MIGRATE   set (non-empty) → skip core `rake db:migrate`
#   REDMINE_PLUGINS_MIGRATE set (non-empty) → run `rake redmine:plugins:migrate`
# We diverge from upstream only in the default: upstream leaves both unset (so
# core migrates but plugins do not), whereas this stack bakes in 13 plugins and
# therefore defaults REDMINE_PLUGINS_MIGRATE=1 to migrate them on every boot.
REDMINE_NO_DB_MIGRATE="${REDMINE_NO_DB_MIGRATE:-}"
REDMINE_PLUGINS_MIGRATE="${REDMINE_PLUGINS_MIGRATE:-1}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [redmine-web] $*"; }
die() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [redmine-web] ERROR: $*" >&2; exit 1; }

# ── 1. Resolve secrets ────────────────────────────────────────────────────────
# read_secret VAR: if ${VAR}_FILE is set, read the value from that file;
# otherwise use ${VAR} as-is. Fails if the resolved value is empty.
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

# Accept the blog's REDMINE_SECRET_KEY_BASE(_FILE); fall back to REDMINE_SECRET_TOKEN.
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

# ── 2. Render configuration from templates ────────────────────────────────────
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

# ── 3. Wait for PostgreSQL ────────────────────────────────────────────────────
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

# ── 4. Database migrations ────────────────────────────────────────────────────
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

# ── 5. Start Apache + Puma (PID 1 supervises both processes) ─────────────
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
