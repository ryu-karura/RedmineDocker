#!/bin/bash
# containers/docker0/entrypoint.sh
#
# PostgreSQL 17 + PostGIS 3.5 container entrypoint.
# Initializes the data directory on first start, then starts PostgreSQL.
#
# Environment variables consumed:
#   POSTGRES_SUPERUSER_PASSWORD  - password for the 'postgres' superuser
#   REDMINE_DB_PASSWORD          - password for the shared 'redmine_adm' user
#
# Both are injected via EnvironmentFile in the Quadlet .container file.

set -euo pipefail

PGDATA="${PGDATA:-/var/lib/pgsql/17/data}"
PGBIN="/usr/pgsql-17/bin"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [entrypoint] $*"
}

# ── Validate required environment variables ─────────────────────────────────
if [ -z "${POSTGRES_SUPERUSER_PASSWORD:-}" ]; then
    echo "ERROR: POSTGRES_SUPERUSER_PASSWORD is not set." >&2
    exit 1
fi
if [ -z "${REDMINE_DB_PASSWORD:-}" ]; then
    echo "ERROR: REDMINE_DB_PASSWORD is not set." >&2
    exit 1
fi

# ── Initialize data directory if not already done ───────────────────────────
if [ ! -f "${PGDATA}/PG_VERSION" ]; then
    log "Initializing PostgreSQL data directory at ${PGDATA} ..."

    "${PGBIN}/initdb" \
        --pgdata="${PGDATA}" \
        --encoding=UTF8 \
        --locale=C.UTF-8 \
        --auth-host=md5 \
        --auth-local=peer \
        --username=postgres

    log "initdb complete."

    # ── Write postgresql.conf overrides ─────────────────────────────────────
    cat >> "${PGDATA}/postgresql.conf" <<EOF

# RedmineDocker overrides
listen_addresses = '*'
max_connections = 100
shared_buffers = 256MB
work_mem = 4MB
maintenance_work_mem = 64MB
log_timezone = 'UTC'
datestyle = 'iso, mdy'
timezone = 'UTC'
lc_messages = 'C'
lc_monetary = 'C'
lc_numeric = 'C'
lc_time = 'C'
default_text_search_config = 'pg_catalog.english'
EOF

    # ── Write pg_hba.conf ───────────────────────────────────────────────────
    # Allow:
    #   - local unix-socket connections for postgres (peer)
    #   - TCP from Podman network 10.89.1.0/24 using md5
    cat > "${PGDATA}/pg_hba.conf" <<EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             all                                     md5
host    all             all             127.0.0.1/32            md5
host    all             all             10.89.1.0/24            md5
EOF

    log "postgresql.conf and pg_hba.conf configured."

    # ── Start PostgreSQL temporarily to run init scripts ────────────────────
    log "Starting PostgreSQL temporarily for initialization ..."
    "${PGBIN}/pg_ctl" -D "${PGDATA}" -o "-c listen_addresses=''" -w start

    # ── Set postgres superuser password ─────────────────────────────────────
    log "Setting postgres superuser password ..."
    "${PGBIN}/psql" -U postgres \
        -c "ALTER USER postgres PASSWORD '${POSTGRES_SUPERUSER_PASSWORD}';"

    # ── Run initialization scripts ──────────────────────────────────────────
    for f in /docker-entrypoint-initdb.d/*.sh; do
        log "Running initialization script: $f"
        bash "$f"
    done

    # ── Stop temporary PostgreSQL ────────────────────────────────────────────
    log "Stopping temporary PostgreSQL ..."
    "${PGBIN}/pg_ctl" -D "${PGDATA}" -m fast -w stop

    log "Initialization complete."
fi

# ── Start PostgreSQL in foreground ──────────────────────────────────────────
log "Starting PostgreSQL ${POSTGRES_VERSION:-17} ..."
exec "${PGBIN}/postgres" -D "${PGDATA}"
