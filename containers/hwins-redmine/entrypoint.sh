#!/bin/bash
# containers/hwins-redmine/entrypoint.sh
#
# Entrypoint for the hwins-redmine container (Redmine 6.1.3, official image +
# plugin stack). Runs as the unprivileged `redmine` user.
#
# Sequence:
#   1. Resolve secrets (supports Docker/Podman *_FILE indirection)
#   2. Render config/database.yml (postgis adapter) and config/configuration.yml
#   3. Wait for PostgreSQL to accept connections
#   4. Run core + plugin database migrations (idempotent)
#   5. exec Puma via `rails server` on TCP :3000 (sub-URI /redmine)
#
# Passwords are never baked into the image or passed as plain env in production;
# they arrive as secret files referenced by *_FILE variables.

set -euo pipefail

REDMINE_HOME="${REDMINE_HOME:-/usr/src/redmine}"
RAILS_ENV="${RAILS_ENV:-production}"
RAILS_RELATIVE_URL_ROOT="${RAILS_RELATIVE_URL_ROOT:-/redmine}"
export RAILS_ENV RAILS_RELATIVE_URL_ROOT

REDMINE_DB_HOST="${REDMINE_DB_HOST:-hwins-db}"
REDMINE_DB_NAME="${REDMINE_DB_NAME:-redmine}"
REDMINE_DB_USER="${REDMINE_DB_USER:-redmine}"
SMTP_HOST="${SMTP_HOST:-localhost}"
SMTP_PORT="${SMTP_PORT:-25}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
REDMINE_PLUGINS_MIGRATE="${REDMINE_PLUGINS_MIGRATE:-1}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [hwins-redmine] $*"; }
die() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [hwins-redmine] ERROR: $*" >&2; exit 1; }

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

export REDMINE_DB_HOST REDMINE_DB_NAME REDMINE_DB_USER REDMINE_DB_PASSWORD
export SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD
export SECRET_KEY_BASE

cd "${REDMINE_HOME}"

# ── 2. Render configuration from templates ────────────────────────────────────
log "Rendering config/database.yml (postgis adapter) ..."
envsubst '${REDMINE_DB_HOST} ${REDMINE_DB_NAME} ${REDMINE_DB_USER} ${REDMINE_DB_PASSWORD}' \
    < config/database.yml.tmpl > config/database.yml
chmod 640 config/database.yml

log "Rendering config/configuration.yml ..."
envsubst '${SMTP_HOST} ${SMTP_PORT} ${SMTP_USER} ${SMTP_PASSWORD}' \
    < config/configuration.yml.tmpl > config/configuration.yml
chmod 640 config/configuration.yml

# ── 3. Wait for PostgreSQL ────────────────────────────────────────────────────
log "Waiting for PostgreSQL at ${REDMINE_DB_HOST}:5432 ..."
export PGPASSWORD="${REDMINE_DB_PASSWORD}"
MAX_WAIT=120
WAITED=0
until pg_isready -h "${REDMINE_DB_HOST}" -p 5432 -U "${REDMINE_DB_USER}" \
        -d "${REDMINE_DB_NAME}" -q 2>/dev/null; do
    [[ ${WAITED} -ge ${MAX_WAIT} ]] && die "PostgreSQL not ready after ${MAX_WAIT}s."
    sleep 2
    (( WAITED += 2 ))
done
log "PostgreSQL is ready."

# ── 4. Database migrations ────────────────────────────────────────────────────
log "Running core database migrations ..."
bundle exec rake db:migrate

if [[ "${REDMINE_PLUGINS_MIGRATE}" == "1" ]]; then
    log "Running plugin migrations ..."
    bundle exec rake redmine:plugins:migrate
fi

# ── 5. Start Puma (foreground / PID 1 after exec) ─────────────────────────────
log "Starting Puma via rails server on :3000 (sub-URI ${RAILS_RELATIVE_URL_ROOT}) ..."
exec bundle exec rails server -b 0.0.0.0 -p 3000 -e "${RAILS_ENV}"
