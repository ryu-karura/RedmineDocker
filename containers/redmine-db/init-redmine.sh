#!/bin/bash
# containers/redmine-db/init-redmine.sh
#
# upstream postgis/postgis entrypoint の
# /docker-entrypoint-initdb.d/ フックから、初回初期化時に 1 回だけ実行されます
# （空データディレクトリで、一時 PostgreSQL サーバ起動中）。
#
# `redmine` ロールと `redmine` DB は POSTGRES_USER / POSTGRES_DB から
# 既に作成済みです。このスクリプトは redmine_gtt が依存する PostGIS 拡張が
# Redmine DB に存在することだけを保証します。SQL はすべて冪等です。

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
