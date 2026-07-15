#!/bin/bash
# scripts/generate-env.sh
#
# Generates a .env file with cryptographically random passwords in the
# repository root (the directory containing this scripts/ directory).
# On a production host cloned to /opt/redmine/containers this resolves to
# /opt/redmine/containers/.env; in a Codespaces/dev checkout it resolves to
# the checkout root, where compose.dev.yaml expects it.
#
# All passwords are 16-character strings containing uppercase letters,
# lowercase letters, and digits (no special characters to avoid shell quoting issues).
#
# Run this script ONCE during initial setup:
#   Production:  sudo bash /opt/redmine/containers/scripts/generate-env.sh
#   Development: bash scripts/generate-env.sh
#
# Set ENV_FILE to override the output path.
#
# The .env file is excluded from git. Keep a secure backup of this file.
# If .env is lost, all containers must be re-initialized with the new passwords.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$(dirname "${SCRIPT_DIR}")/.env}"

if [ -f "${ENV_FILE}" ]; then
    echo "WARNING: ${ENV_FILE} already exists."
    read -r -p "Overwrite it with new passwords? This will require re-initializing all containers. [y/N] " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        echo "Aborted. Existing .env retained."
        exit 0
    fi
fi

# Random generators read a finite chunk of /dev/urandom instead of the
# endless stream: with an endless stream, tr keeps writing after the final
# `head` exits and dies from SIGPIPE, which aborts the script under
# `set -o pipefail`. The chunk sizes leave a wide safety margin over the
# required output lengths; the results are length-checked below.

# Generate a 16-character random alphanumeric password (uppercase + lowercase + digits)
gen_password() {
    head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 16
}

# Generate a long secret key base (128 hex characters, standard for Rails)
gen_secret() {
    head -c 65536 /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | head -c 128
}

echo "Generating passwords and secret tokens ..."

POSTGRES_SUPERUSER_PASSWORD=$(gen_password)
REDMINE_DB_PASSWORD=$(gen_password)
REDMINE_SECRET_TOKEN=$(gen_secret)

if [ "${#POSTGRES_SUPERUSER_PASSWORD}" -ne 16 ] \
        || [ "${#REDMINE_DB_PASSWORD}" -ne 16 ] \
        || [ "${#REDMINE_SECRET_TOKEN}" -ne 128 ]; then
    echo "ERROR: generated secrets have unexpected lengths; aborting." >&2
    exit 1
fi

# Write the .env file
cat > "${ENV_FILE}" <<EOF
# RedmineDocker Environment Variables
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# WARNING: This file contains sensitive credentials.
#          Do NOT commit this file to git.
#          Store a secure backup outside of the repository.

# ── PostgreSQL Superuser Password ─────────────────────────────────────────────
# Used by the 'postgres' superuser for administration.
# POSTGRES_PASSWORD is the upstream image variable; keep the compatibility alias too.
POSTGRES_SUPERUSER_PASSWORD=${POSTGRES_SUPERUSER_PASSWORD}
POSTGRES_PASSWORD=${POSTGRES_SUPERUSER_PASSWORD}

# ── Shared Redmine Database User Password ─────────────────────────────────────
# Used by the 'redmine_adm' DB user for the production Redmine database.
REDMINE_DB_PASSWORD=${REDMINE_DB_PASSWORD}

# ── Redmine Secret Key Base ───────────────────────────────────────────────────
# Used to sign and encrypt session cookies.
# DO NOT reuse or change after initial setup without re-logging all users.
REDMINE_SECRET_TOKEN=${REDMINE_SECRET_TOKEN}

# ── SMTP Configuration ────────────────────────────────────────────────────────
# Configure these for outbound email notifications.
SMTP_HOST=localhost
SMTP_PORT=25
SMTP_USER=
SMTP_PASSWORD=
EOF

chmod 600 "${ENV_FILE}"
chown root:root "${ENV_FILE}" 2>/dev/null || true

echo ""
echo "✓ Environment file created: ${ENV_FILE}"
echo "  Permissions: 600 (readable by root only)"
echo ""
echo "  POSTGRES_SUPERUSER_PASSWORD: $(echo "${POSTGRES_SUPERUSER_PASSWORD}" | sed 's/./*/g') (16 chars)"
echo "  REDMINE_DB_PASSWORD:         $(echo "${REDMINE_DB_PASSWORD}" | sed 's/./*/g') (16 chars)"
echo "  REDMINE_SECRET_TOKEN:        [128 hex chars]"
echo ""
echo "Next steps:"
echo "  1. Edit ${ENV_FILE} to configure SMTP settings if email is needed."
echo "  2. Build container images: see docs/Setup.md Step 5."
echo "  3. Store a secure backup of ${ENV_FILE} outside this repository."
