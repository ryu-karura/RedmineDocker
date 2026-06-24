#!/bin/bash
# scripts/generate-env.sh
#
# Generates /opt/redmine/containers/.env with cryptographically random passwords.
#
# All passwords are 16-character strings containing uppercase letters,
# lowercase letters, and digits (no special characters to avoid shell quoting issues).
#
# Run this script ONCE during initial setup:
#   sudo bash /opt/redmine/containers/scripts/generate-env.sh
#
# The .env file is excluded from git. Keep a secure backup of this file.
# If .env is lost, all containers must be re-initialized with the new passwords.

set -euo pipefail

ENV_FILE="/opt/redmine/containers/.env"

if [ -f "${ENV_FILE}" ]; then
    echo "WARNING: ${ENV_FILE} already exists."
    read -r -p "Overwrite it with new passwords? This will require re-initializing all containers. [y/N] " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        echo "Aborted. Existing .env retained."
        exit 0
    fi
fi

# Generate a 16-character random alphanumeric password (uppercase + lowercase + digits)
gen_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

# Generate a long secret key base (64 hex characters, standard for Rails)
gen_secret() {
    LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 128
}

echo "Generating passwords and secret tokens ..."

POSTGRES_SUPERUSER_PASSWORD=$(gen_password)
REDMINE_DB_PASSWORD=$(gen_password)
REDMINE1_SECRET_TOKEN=$(gen_secret)
REDMINE2_SECRET_TOKEN=$(gen_secret)
REDMINE3_SECRET_TOKEN=$(gen_secret)

# Write the .env file
cat > "${ENV_FILE}" <<EOF
# RedmineDocker Environment Variables
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# WARNING: This file contains sensitive credentials.
#          Do NOT commit this file to git.
#          Store a secure backup outside of the repository.

# ── PostgreSQL Superuser Password ─────────────────────────────────────────────
# Used by the 'postgres' superuser for administration.
POSTGRES_SUPERUSER_PASSWORD=${POSTGRES_SUPERUSER_PASSWORD}

# ── Shared Redmine Database User Password ─────────────────────────────────────
# Used by the 'redmine_adm' DB user across all three Redmine databases.
REDMINE_DB_PASSWORD=${REDMINE_DB_PASSWORD}

# ── Redmine Secret Key Base ───────────────────────────────────────────────────
# Used to sign and encrypt session cookies. Each environment has its own key.
# DO NOT reuse across environments.
REDMINE_SECRET_TOKEN=${REDMINE1_SECRET_TOKEN}
REDMINE2_SECRET_TOKEN=${REDMINE2_SECRET_TOKEN}
REDMINE3_SECRET_TOKEN=${REDMINE3_SECRET_TOKEN}

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
echo "  REDMINE1_SECRET_TOKEN:       [128 hex chars]"
echo "  REDMINE2_SECRET_TOKEN:       [128 hex chars]"
echo "  REDMINE3_SECRET_TOKEN:       [128 hex chars]"
echo ""
echo "Next steps:"
echo "  1. Edit ${ENV_FILE} to configure SMTP settings if email is needed."
echo "  2. Build container images: see docs/Setup.md Step 5."
echo "  3. Store a secure backup of ${ENV_FILE} outside this repository."
