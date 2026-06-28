#!/bin/bash
# containers/docker0/init-postgis.sh
#
# PostgreSQL initialization script for RedmineDocker.
# Called by the upstream postgis/postgis entrypoint during first-time
# initialization, while PostgreSQL is running temporarily for setup.
#
# Creates:
#   - Database user 'redmine_adm' (used by the production Redmine container)
#   - Grants for the PostGIS-enabled database: redmine_prod
#
# The REDMINE_DB_PASSWORD environment variable must be set before this script runs.

set -euo pipefail

PGUSER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-redmine_prod}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [init-postgis] $*"
}

if [ -z "${REDMINE_DB_PASSWORD:-}" ]; then
    echo "ERROR: REDMINE_DB_PASSWORD is not set in init-postgis.sh" >&2
    exit 1
fi

log "Creating Redmine database user 'redmine_adm' ..."
psql --username "${PGUSER}" --dbname postgres \
    --set=ON_ERROR_STOP=1 \
    --set=redmine_db_password="${REDMINE_DB_PASSWORD}" <<'SQL'
SELECT CASE
    WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'redmine_adm') THEN
        format(
            'ALTER ROLE redmine_adm LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT',
            :'redmine_db_password'
        )
    ELSE
        format(
            'CREATE ROLE redmine_adm LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT',
            :'redmine_db_password'
        )
END
\gexec
SQL

log "Granting ownership and privileges on ${POSTGRES_DB} ..."
psql --username "${PGUSER}" --dbname postgres \
    --set=ON_ERROR_STOP=1 \
    --set=redmine_db_name="${POSTGRES_DB}" <<'SQL'
ALTER DATABASE :"redmine_db_name" OWNER TO redmine_adm;
GRANT ALL PRIVILEGES ON DATABASE :"redmine_db_name" TO redmine_adm;
SQL

log "Ensuring PostGIS extensions and schema privileges in ${POSTGRES_DB} ..."
psql --username "${PGUSER}" --dbname "${POSTGRES_DB}" \
    --set=ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
DO
$$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'fuzzystrmatch') THEN
        CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'postgis_tiger_geocoder') THEN
        CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder;
    END IF;
END
$$;
GRANT USAGE ON SCHEMA public TO redmine_adm;
GRANT USAGE ON SCHEMA topology TO redmine_adm;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO redmine_adm;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO redmine_adm;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO redmine_adm;
ALTER DEFAULT PRIVILEGES FOR ROLE redmine_adm IN SCHEMA public
    GRANT ALL ON TABLES TO redmine_adm;
ALTER DEFAULT PRIVILEGES FOR ROLE redmine_adm IN SCHEMA public
    GRANT ALL ON SEQUENCES TO redmine_adm;
ALTER DEFAULT PRIVILEGES FOR ROLE redmine_adm IN SCHEMA public
    GRANT ALL ON FUNCTIONS TO redmine_adm;
SQL

log "Database and extensions initialized successfully."
