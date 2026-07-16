#!/bin/bash
# containers/redmine-db/init-redmine.sh
#
# Runs once, from the upstream postgis/postgis entrypoint's
# /docker-entrypoint-initdb.d/ hook, during first-time initialisation of an
# empty data directory (while a temporary PostgreSQL server is running).
#
# The `redmine` role and `redmine` database are already created by the image
# from POSTGRES_USER / POSTGRES_DB. Here we only make sure the PostGIS
# extensions that the redmine_gtt plugin depends on exist in the Redmine
# database. All statements are idempotent.

set -euo pipefail

PGUSER="${POSTGRES_USER:-redmine}"
DB="${POSTGRES_DB:-redmine}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [init-redmine] $*"
}

log "Ensuring PostGIS extensions in database '${DB}' ..."
psql --username "${PGUSER}" --dbname "${DB}" --set=ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
SQL

log "Database extensions initialised successfully."
