#!/bin/bash
# scripts/pin-static-image.sh
#
# Pins the hwins-static base image (docker.io/library/httpd:2.4) by digest, as
# required by issue #18 ("取得後にダイジェストを固定" — pin the digest after
# pulling). Run this on a host with registry access; it pulls the current 2.4
# image, resolves its repo digest, and rewrites the FROM line in
# containers/hwins-static/Containerfile to a digest-pinned reference.
#
# Usage:
#   bash scripts/pin-static-image.sh            # uses podman if present, else docker
#   ENGINE=docker bash scripts/pin-static-image.sh
#
# Re-running after a new httpd 2.4 release re-pins to the newest digest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
CONTAINERFILE="${REPO_ROOT}/containers/hwins-static/Containerfile"
IMAGE="docker.io/library/httpd:2.4"

ENGINE="${ENGINE:-}"
if [ -z "${ENGINE}" ]; then
    if command -v podman >/dev/null 2>&1; then ENGINE=podman
    elif command -v docker >/dev/null 2>&1; then ENGINE=docker
    else echo "ERROR: neither podman nor docker found." >&2; exit 1
    fi
fi

[ -f "${CONTAINERFILE}" ] || { echo "ERROR: ${CONTAINERFILE} not found." >&2; exit 1; }

echo "Pulling ${IMAGE} with ${ENGINE} ..."
"${ENGINE}" pull "${IMAGE}"

# Extract the repo digest (sha256:...) from the pulled image's RepoDigests.
DIGEST="$("${ENGINE}" image inspect "${IMAGE}" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    | sed -n 's|.*@\(sha256:[0-9a-f]\{64\}\).*|\1|p' | head -n1)"

if [ -z "${DIGEST}" ]; then
    echo "ERROR: could not determine the digest for ${IMAGE}." >&2
    exit 1
fi

echo "Resolved digest: ${DIGEST}"

# Rewrite the FROM line (tag or previously-pinned digest) to the new digest.
sed -i -E \
    "s|^FROM docker\.io/library/httpd:2\.4(@sha256:[0-9a-f]{64})?|FROM docker.io/library/httpd:2.4@${DIGEST}|" \
    "${CONTAINERFILE}"

echo "✓ Updated FROM line in ${CONTAINERFILE}:"
grep -n '^FROM ' "${CONTAINERFILE}"
