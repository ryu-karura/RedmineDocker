#!/bin/bash
# containers/redmine-web/healthcheck.sh
#
# redmine-web コンテナのヘルスチェック
# （install path: /usr/local/bin/redmine-healthcheck.sh）。
#
# usage: /usr/local/bin/redmine-healthcheck.sh
#
# compose.dev.yaml の healthcheck.test から呼ばれます（本番も同じ compose 定義を
# 使うため、開発・本番で同一のヘルスチェックです）。判定ロジックをイメージ内の
# このスクリプトへ寄せている理由は 2 つあります:
#   - サブ URI (RAILS_RELATIVE_URL_ROOT) と REDMINE_WEB_SERVER に応じて検証内容が
#     変わるため、コンテナの環境変数から解決できる場所に置きたい
#   - 同じシェル 1 行を複数の compose ファイルへ二重にベタ書きすると
#     dev/prod の lockstep が崩れる
#
# 検証内容（REDMINE_WEB_SERVER で変わります）:
#   共通         Apache(:80) 経由で ${RAILS_RELATIVE_URL_ROOT}/login が 200
#   passenger    Puma は存在しないため直叩きの検証は行いません
#                （mod_passenger が Apache 内でアプリを起動するため。7 系の既定）
#   puma のみ    Puma(:${REDMINE_PUMA_PORT}) 直叩きでも同 URL が 200
#                （config.ru がサブ URI を map しなくなる回帰の検知）

set -euo pipefail

RAILS_RELATIVE_URL_ROOT="${RAILS_RELATIVE_URL_ROOT:-/redmine}"
REDMINE_PUMA_PORT="${REDMINE_PUMA_PORT:-3000}"
# 既定値はイメージの ENV REDMINE_WEB_SERVER（7 系 = passenger、
# 5 系 / 6 系 = puma）から渡ります。ここでのフォールバックは保険です。
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
