#!/bin/bash
# scripts/generate-secrets.sh
#
# Generates the secret files consumed by the hwins stack:
#   - secrets/db_password.txt      : PostgreSQL password for the `redmine` role
#                                    (also the app DB password — single user model)
#   - secrets/secret_key_base.txt  : Rails secret_key_base for Redmine
#
# These files are referenced by compose.dev.yaml (`secrets:`) in development and
# are the source for `podman secret create` in production (see docs/Setup.md).
# They are git-ignored; keep a secure backup outside the repository.
#
# Usage:
#   bash scripts/generate-secrets.sh
#
# Set SECRETS_DIR to override the output directory.

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

# Read a finite chunk of /dev/urandom (not an endless stream) so `tr` does not
# die from SIGPIPE under `set -o pipefail` after `head` exits.

# 24-character alphanumeric password (no special chars → no shell-quoting issues)
gen_password() {
    head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24
}

# 128 hex characters — standard length for a Rails secret_key_base
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

# No trailing newline: the value IS the whole file (Postgres/Redmine read it verbatim).
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
