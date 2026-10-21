#!/usr/bin/env bash
# Idempotent GitOps apply. Compose loads .env; Traefik gets ACME_EMAIL / MODEL_API_FQDN via Compose.
# docker model pull reads HF_TOKEN. Accept an older HUGGING_FACE_HUB_TOKEN name in .env.
set -euo pipefail
cd "$(dirname "$0")"
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
if [[ -z "${HF_TOKEN:-}" && -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
  export HF_TOKEN="$HUGGING_FACE_HUB_TOKEN"
fi
docker compose up -d --remove-orphans
sudo systemctl restart docker-model-gateway.service
