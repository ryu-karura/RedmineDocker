#!/bin/bash
# .devcontainer/post-create.sh
#
# Runs once after the dev container is created (GitHub Codespaces / VS Code).
# Installs the linting tools used by this repository and verifies that the
# Docker daemon provided by the docker-in-docker feature is available.

set -euo pipefail

sudo apt-get update
sudo apt-get install -y --no-install-recommends shellcheck
sudo rm -rf /var/lib/apt/lists/*

echo ""
echo "Tool versions:"
shellcheck --version | head -2
docker --version
docker compose version

echo ""
echo "Next steps (see docs/Setup.md, '開発環境 B — GitHub Codespaces'):"
echo "  1. bash scripts/generate-secrets.sh    # creates ./secrets/*.txt"
echo "  2. docker compose -f compose.dev.yaml up --build -d"
echo "  3. Open http://localhost:8080/redmine/ (forwarded port 8080)"
