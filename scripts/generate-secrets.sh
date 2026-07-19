#!/bin/bash
# scripts/generate-secrets.sh
#
# redmine スタックで使うシークレットファイルを生成します:
#   - secrets/db_password.txt      : `redmine` ロール用 PostgreSQL パスワード
#                                    （単一ユーザーモデルのためアプリ DB パスワードも兼用）
#   - secrets/secret_key_base.txt  : Redmine 用 Rails secret_key_base
#
# これらは開発時は compose.dev.yaml の `secrets:` から参照され、
# 本番時は `podman secret create` の入力ファイルになります（docs/Setup.md 参照）。
# git には含めないため、リポジトリ外へ安全にバックアップしてください。
#
# 使い方:
#   bash scripts/generate-secrets.sh
#
# 出力先を変更する場合は SECRETS_DIR を設定します。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="${SECRETS_DIR:-$(dirname "${SCRIPT_DIR}")/secrets}"

DB_PASSWORD_FILE="${SECRETS_DIR}/db_password.txt"
SECRET_KEY_BASE_FILE="${SECRETS_DIR}/secret_key_base.txt"

if [ -f "${DB_PASSWORD_FILE}" ] || [ -f "${SECRET_KEY_BASE_FILE}" ]; then
    echo "WARNING: secret files already exist in ${SECRETS_DIR}."
    read -r -p "Overwrite them? This requires re-initialising the database. [y/N] " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        echo "Aborted. Existing secrets retained."
        exit 0
    fi
fi

mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

# /dev/urandom は有限サイズだけ読み込みます（無限ストリームを避ける）。
# `set -o pipefail` 下で `head` 終了後に `tr` が SIGPIPE で落ちないようにするためです。

# 英数字 24 文字パスワード（記号なしでシェルクオート事故を回避）
gen_password() {
    head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24
}

# 16進 128 文字（Rails secret_key_base の標準長）
gen_secret() {
    head -c 65536 /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | head -c 128
}

echo "Generating secrets in ${SECRETS_DIR} ..."

DB_PASSWORD="$(gen_password)"
SECRET_KEY_BASE="$(gen_secret)"

if [ "${#DB_PASSWORD}" -ne 24 ] || [ "${#SECRET_KEY_BASE}" -ne 128 ]; then
    echo "ERROR: generated secrets have unexpected lengths; aborting." >&2
    exit 1
fi

# 改行は付けない: ファイル全体を値としてそのまま読み取るため。
printf '%s' "${DB_PASSWORD}"     > "${DB_PASSWORD_FILE}"
printf '%s' "${SECRET_KEY_BASE}" > "${SECRET_KEY_BASE_FILE}"
chmod 600 "${DB_PASSWORD_FILE}" "${SECRET_KEY_BASE_FILE}"

echo ""
echo "✓ Secrets written (mode 600):"
echo "    ${DB_PASSWORD_FILE}"
echo "    ${SECRET_KEY_BASE_FILE}"
echo ""
echo "Development (Docker Compose): ready — run"
echo "    docker compose -f compose.dev.yaml up --build -d"
echo ""
echo "Production (Podman): register the files as Podman secrets, e.g."
echo "    podman secret create db_password     ${DB_PASSWORD_FILE}"
echo "    podman secret create secret_key_base ${SECRET_KEY_BASE_FILE}"
echo ""
echo "Keep a secure backup of these files outside the repository."
