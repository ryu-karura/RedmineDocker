#!/bin/bash
# containers/docker0/entrypoint.sh
#
# PostgreSQL first-run configuration hook for Docker0.
#
# The upstream postgis/postgis:18-master image executes this script from
# /docker-entrypoint-initdb.d/ after initdb and before the final PostgreSQL
# server start.

set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/18/docker}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [configure-postgres] $*"
}

if [ ! -f "${PGDATA}/postgresql.conf" ]; then
    echo "ERROR: postgresql.conf not found in ${PGDATA}" >&2
    exit 1
fi

log "Applying RedmineDocker PostgreSQL settings ..."
cat >> "${PGDATA}/postgresql.conf" <<'EOF'

# RedmineDocker overrides
max_connections = 100
shared_buffers = '256MB'
work_mem = '4MB'
maintenance_work_mem = '64MB'
log_timezone = 'UTC'
datestyle = 'iso, mdy'
timezone = 'UTC'
lc_messages = 'C'
lc_monetary = 'C'
lc_numeric = 'C'
lc_time = 'C'
default_text_search_config = 'pg_catalog.english'
EOF
