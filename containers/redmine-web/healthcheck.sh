#!/bin/bash
# containers/redmine-web/healthcheck.sh
#
# redmine-web コンテナのヘルスチェック
# （install path: /usr/local/bin/redmine-healthcheck.sh）。
#
# usage: /usr/local/bin/redmine-healthcheck.sh
#
# compose.dev.yaml の healthcheck.test と quadlets/redmine-web.container の
# HealthCmd= から呼ばれます。判定ロジックをイメージ内のこのスクリプトへ寄せて
# いる理由は 2 つあります:
#   - Podman Quadlet の HealthCmd= は変数展開されないため、サブ URI や
#     REDMINE_WEB_SERVER をユニット側で解決できない
#   - 同じシェル 1 行を compose と quadlet に二重にベタ書きすると
#     dev/prod の lockstep が崩れる
#
# 検証内容（REDMINE_WEB_SERVER で変わります）:
#   共通         Apache(:80) 経由で ${RAILS_RELATIVE_URL_ROOT}/login が 200
#   puma のみ    Puma(:${REDMINE_PUMA_PORT}) 直叩きでも同 URL が 200
#                （config.ru がサブ URI を map しなくなる回帰の検知）
#   passenger    Puma は存在しないため直叩きの検証は行いません
#                （mod_passenger が Apache 内でアプリを起動するため）

set -euo pipefail

RAILS_RELATIVE_URL_ROOT="${RAILS_RELATIVE_URL_ROOT:-/redmine}"
REDMINE_PUMA_PORT="${REDMINE_PUMA_PORT:-3000}"
REDMINE_WEB_SERVER="${REDMINE_WEB_SERVER:-puma}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [redmine-web/healthcheck] $*"; }
die() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [redmine-web/healthcheck] ERROR: $*" >&2; exit 1; }

curl -f -s -o /dev/null "http://localhost${RAILS_RELATIVE_URL_ROOT}/login" \
    || die "Apache healthcheck failed (http://localhost${RAILS_RELATIVE_URL_ROOT}/login)."

if [[ "${REDMINE_WEB_SERVER}" == "puma" ]]; then
    curl -f -s -o /dev/null \
        "http://127.0.0.1:${REDMINE_PUMA_PORT}${RAILS_RELATIVE_URL_ROOT}/login" \
        || die "Puma healthcheck failed (http://127.0.0.1:${REDMINE_PUMA_PORT}${RAILS_RELATIVE_URL_ROOT}/login)."
fi

log "OK (server=${REDMINE_WEB_SERVER})"
