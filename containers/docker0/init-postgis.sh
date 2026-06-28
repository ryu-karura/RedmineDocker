#!/bin/bash
# containers/docker0/init-postgis.sh
#
# PostgreSQL initialization script for RedmineDocker.
# Called by the entrypoint after initdb, while PostgreSQL is running
# in single-user (no-listen) mode.
#
# Creates:
#   - Database user 'redmine_adm' (used by the production Redmine container)
#   - PostGIS-enabled database: redmine_prod
#
# The REDMINE_DB_PASSWORD environment variable must be set before this script runs.

set -euo pipefail

PGBIN="/usr/pgsql-17/bin"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [init-postgis] $*"
}

if [ -z "${REDMINE_DB_PASSWORD:-}" ]; then
    echo "ERROR: REDMINE_DB_PASSWORD is not set in init-postgis.sh" >&2
    exit 1
fi

log "Creating Redmine database user 'redmine_adm' ..."
"${PGBIN}/psql" -U postgres <<-SQL
CREATE USER redmine_adm
    WITH PASSWORD '${REDMINE_DB_PASSWORD}'
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    INHERIT
    LOGIN;
SQL

for DBNAME in redmine_prod; do
    log "Creating database: ${DBNAME} ..."
    "${PGBIN}/psql" -U postgres <<-SQL
    CREATE DATABASE ${DBNAME}
        OWNER = redmine_adm
        ENCODING = 'UTF8'
        LC_COLLATE = 'C.UTF-8'
        LC_CTYPE = 'C.UTF-8'
        TEMPLATE = template0;
SQL

    log "Enabling PostGIS extensions in ${DBNAME} ..."
    "${PGBIN}/psql" -U postgres -d "${DBNAME}" <<-SQL
    CREATE EXTENSION IF NOT EXISTS postgis;
    CREATE EXTENSION IF NOT EXISTS postgis_topology;
    CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
    CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder;
    -- Grant usage on PostGIS schemas to redmine_adm
    GRANT USAGE ON SCHEMA public TO redmine_adm;
    GRANT USAGE ON SCHEMA topology TO redmine_adm;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO redmine_adm;
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO redmine_adm;
    GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO redmine_adm;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT ALL ON TABLES TO redmine_adm;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT ALL ON SEQUENCES TO redmine_adm;
SQL
    log "Database ${DBNAME} created and PostGIS enabled."
done

log "Database and extensions initialized successfully."
