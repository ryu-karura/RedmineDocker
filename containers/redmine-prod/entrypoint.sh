#!/bin/bash
# containers/redmine-prod/entrypoint.sh
#
# Entrypoint for the redmine-prod container (Production Redmine 6.1.3).
#
# Sequence:
#   1. Validate required environment variables
#   2. Render config/database.yml from template
#   3. Render config/configuration.yml from template
#   4. Write config/secrets.yml from REDMINE_SECRET_TOKEN
#   5. Wait for PostgreSQL to be ready
#   6. Run database migrations (idempotent — safe on every start)
#   7. Run plugin migrations (idempotent)
#   8. Compile assets if not already compiled (checks public/assets/manifest-*.json)
#   9. Set file permissions on writable directories
#  10. Start Apache httpd in background
#  11. Start Puma in foreground (becomes PID 1 after exec)
#
# Environment variables (from EnvironmentFile in Quadlet):
#   REDMINE_DB_HOST         — database container hostname (default: redmine-db)
#   REDMINE_DB_NAME         — database name (default: redmine_prod)
#   REDMINE_DB_USER         — database user (default: redmine_adm)
#   REDMINE_DB_PASSWORD     — database password (required)
#   REDMINE_SECRET_TOKEN    — secret key base (required, generate once per env)
#   SMTP_HOST               — SMTP server (default: localhost)
#   SMTP_PORT               — SMTP port (default: 25)
#   SMTP_USER               — SMTP username (default: empty)
#   SMTP_PASSWORD           — SMTP password (default: empty)

set -euo pipefail

RAILS_ENV="${RAILS_ENV:-production}"
RAILS_RELATIVE_URL_ROOT="${RAILS_RELATIVE_URL_ROOT:-/redmine}"
REDMINE_HOME="${REDMINE_HOME:-/opt/redmine/app}"
RBENV_ROOT="${RBENV_ROOT:-/usr/local/rbenv}"

export PATH="${RBENV_ROOT}/bin:${RBENV_ROOT}/shims:${PATH}"
export RAILS_ENV
export RAILS_RELATIVE_URL_ROOT

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [entrypoint] $*"; }
die() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [entrypoint] ERROR: $*" >&2; exit 1; }

# ── 1. Validate required variables ───────────────────────────────────────────
[[ -z "${REDMINE_DB_PASSWORD:-}" ]] && die "REDMINE_DB_PASSWORD is not set."
[[ -z "${REDMINE_SECRET_TOKEN:-}" ]] && die "REDMINE_SECRET_TOKEN is not set."

REDMINE_DB_HOST="${REDMINE_DB_HOST:-redmine-db}"
REDMINE_DB_NAME="${REDMINE_DB_NAME:-redmine_prod}"
REDMINE_DB_USER="${REDMINE_DB_USER:-redmine_adm}"
SMTP_HOST="${SMTP_HOST:-localhost}"
SMTP_PORT="${SMTP_PORT:-25}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"

export REDMINE_DB_HOST REDMINE_DB_NAME REDMINE_DB_USER REDMINE_DB_PASSWORD
export SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD

# ── 2. Render database.yml ────────────────────────────────────────────────────
log "Rendering config/database.yml from template ..."
envsubst '${REDMINE_DB_HOST} ${REDMINE_DB_NAME} ${REDMINE_DB_USER} ${REDMINE_DB_PASSWORD}' \
    < "${REDMINE_HOME}/config/database.yml.tmpl" \
    > "${REDMINE_HOME}/config/database.yml"
chmod 640 "${REDMINE_HOME}/config/database.yml"
chown redmine_adm:redmine "${REDMINE_HOME}/config/database.yml"

# ── 3. Render configuration.yml ──────────────────────────────────────────────
log "Rendering config/configuration.yml from template ..."
envsubst '${SMTP_HOST} ${SMTP_PORT} ${SMTP_USER} ${SMTP_PASSWORD}' \
    < "${REDMINE_HOME}/config/configuration.yml.tmpl" \
    > "${REDMINE_HOME}/config/configuration.yml"
chmod 640 "${REDMINE_HOME}/config/configuration.yml"
chown redmine_adm:redmine "${REDMINE_HOME}/config/configuration.yml"

# ── 4. Write secrets.yml ──────────────────────────────────────────────────────
log "Writing config/secrets.yml ..."
cat > "${REDMINE_HOME}/config/secrets.yml" <<-YAML
${RAILS_ENV}:
  secret_key_base: ${REDMINE_SECRET_TOKEN}
YAML
chmod 640 "${REDMINE_HOME}/config/secrets.yml"
chown redmine_adm:redmine "${REDMINE_HOME}/config/secrets.yml"

# ── 5. Wait for PostgreSQL ────────────────────────────────────────────────────
log "Waiting for PostgreSQL at ${REDMINE_DB_HOST}:5432 ..."
PGPASSWORD="${REDMINE_DB_PASSWORD}"
export PGPASSWORD
MAX_WAIT=120
WAITED=0
until pg_isready -h "${REDMINE_DB_HOST}" -p 5432 -U "${REDMINE_DB_USER}" \
        -d "${REDMINE_DB_NAME}" -q 2>/dev/null; do
    if [[ ${WAITED} -ge ${MAX_WAIT} ]]; then
        die "PostgreSQL did not become ready within ${MAX_WAIT} seconds."
    fi
    sleep 2
    (( WAITED += 2 ))
    log "  ... waiting (${WAITED}/${MAX_WAIT}s)"
done
log "PostgreSQL is ready."

# ── 6. Run Redmine database migrations ───────────────────────────────────────
log "Running database migrations ..."
cd "${REDMINE_HOME}"
sudo -u redmine_adm -E \
    "${RBENV_ROOT}/shims/bundle" exec rake db:migrate RAILS_ENV="${RAILS_ENV}"

# ── 7. Run plugin migrations ──────────────────────────────────────────────────
log "Running plugin migrations ..."
sudo -u redmine_adm -E \
    "${RBENV_ROOT}/shims/bundle" exec rake redmine:plugins:migrate \
    RAILS_ENV="${RAILS_ENV}"

# ── 8. Compile assets (only if not already compiled) ─────────────────────────
MANIFEST=$(find "${REDMINE_HOME}/public/assets" -name ".sprockets-manifest-*.json" 2>/dev/null | head -1)
if [[ -z "${MANIFEST}" ]]; then
    log "Compiling static assets (first start or assets cleared) ..."
    sudo -u redmine_adm -E \
        RAILS_RELATIVE_URL_ROOT="${RAILS_RELATIVE_URL_ROOT}" \
        "${RBENV_ROOT}/shims/bundle" exec rake assets:precompile \
        RAILS_ENV="${RAILS_ENV}"
    log "Asset precompilation complete."
else
    log "Assets already compiled (${MANIFEST}). Skipping precompile."
fi

# ── 9. Set permissions on writable directories ───────────────────────────────
log "Ensuring correct permissions on writable directories ..."
chown -R redmine_adm:redmine \
    "${REDMINE_HOME}/files" \
    "${REDMINE_HOME}/log" \
    "${REDMINE_HOME}/tmp" \
    "${REDMINE_HOME}/public/assets" \
    "${REDMINE_HOME}/public/plugin_assets"
chmod -R 755 \
    "${REDMINE_HOME}/files" \
    "${REDMINE_HOME}/log" \
    "${REDMINE_HOME}/tmp"

# ── 10. Start Apache httpd ────────────────────────────────────────────────────
log "Starting Apache httpd ..."
httpd -DFOREGROUND &
HTTPD_PID=$!

# ── 11. Start Puma in foreground (PID 1) ─────────────────────────────────────
log "Starting Puma (RAILS_ENV=${RAILS_ENV}, SUBURI=${RAILS_RELATIVE_URL_ROOT}) ..."
exec sudo -u redmine_adm -E \
    RAILS_ENV="${RAILS_ENV}" \
    RAILS_RELATIVE_URL_ROOT="${RAILS_RELATIVE_URL_ROOT}" \
    REDMINE_DB_HOST="${REDMINE_DB_HOST}" \
    REDMINE_DB_NAME="${REDMINE_DB_NAME}" \
    REDMINE_DB_USER="${REDMINE_DB_USER}" \
    REDMINE_DB_PASSWORD="${REDMINE_DB_PASSWORD}" \
    REDMINE_SECRET_TOKEN="${REDMINE_SECRET_TOKEN}" \
    "${RBENV_ROOT}/shims/bundle" exec puma \
        -C "${REDMINE_HOME}/config/puma.rb" \
        --dir "${REDMINE_HOME}"
