#!/usr/bin/env bash
# Idempotent GitOps apply. Compose loads .env; Traefik gets ACME_EMAIL / MODEL_API_FQDN via Compose.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p letsencrypt
[[ -f letsencrypt/acme.json ]] || install -m 0600 /dev/null letsencrypt/acme.json
docker compose up -d --remove-orphans
sudo systemctl restart docker-model-gateway.service
