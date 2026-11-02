#!/usr/bin/env bash
# Pull origin/main and reapply the compose project. Stdout goes to the journal
# and to /var/log/llm-gitops.log.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p /var/log
exec > >(tee --append /var/log/llm-gitops.log) 2>&1

echo "=== $(date --iso-8601=seconds) gitops apply ==="
git fetch origin
git reset --hard origin/main
docker compose pull
docker compose up --detach --remove-orphans
