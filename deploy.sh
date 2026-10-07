#!/usr/bin/env bash
# Idempotent GitOps apply for llm-configs.
# Run from the VM checkout after pulling YAML changes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

COMPOSE_FILES=(
  -f compose.yaml
  -f models/medgemma/compose.yml
  -f models/qwen/compose.yml
)

GATEWAY_ENV_FILE="${GATEWAY_ENV_FILE:-/etc/docker-model-gateway.env}"
UNIT_SRC="${ROOT}/systemd/docker-model-gateway.service"
UNIT_DST="/etc/systemd/system/docker-model-gateway.service"
BRIDGE_IP="172.30.50.1"
BRIDGE_IFACE="model_api_br"
BRIDGE_NET="model_api_net"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

load_env() {
  # Assumes operator install already created .env and /etc/docker-model-gateway.env.
  if [[ -f "${ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${ROOT}/.env"
    set +a
  fi
  if [[ -f "${GATEWAY_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "${GATEWAY_ENV_FILE}"
    set +a
  fi

  export LLM_CONFIGS_ROOT="${LLM_CONFIGS_ROOT:-${ROOT}}"
  export MODEL_API_FQDN ACME_EMAIL
  export HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-}"
  export HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN}}"
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-llm-configs}"
}

render_traefik() {
  log "Rendering Traefik config from templates"
  mkdir -p "${ROOT}/traefik/dynamic" "${ROOT}/letsencrypt"
  if [[ ! -f "${ROOT}/letsencrypt/acme.json" ]]; then
    install -m 0600 /dev/null "${ROOT}/letsencrypt/acme.json"
  else
    chmod 0600 "${ROOT}/letsencrypt/acme.json"
  fi

  envsubst '${ACME_EMAIL}' \
    < "${ROOT}/traefik/traefik.yml.tpl" \
    > "${ROOT}/traefik/traefik.yml"
  envsubst '${MODEL_API_FQDN}' \
    < "${ROOT}/traefik/templates/model-api.yml.tpl" \
    > "${ROOT}/traefik/dynamic/model-api.yml"
}

compose() {
  docker compose "${COMPOSE_FILES[@]}" "$@"
}

ensure_gateway_env_root() {
  if grep -q '^LLM_CONFIGS_ROOT=' "${GATEWAY_ENV_FILE}" 2>/dev/null; then
    sudo sed -i "s|^LLM_CONFIGS_ROOT=.*|LLM_CONFIGS_ROOT=${LLM_CONFIGS_ROOT}|" "${GATEWAY_ENV_FILE}"
  else
    printf '\nLLM_CONFIGS_ROOT=%s\n' "${LLM_CONFIGS_ROOT}" | sudo tee -a "${GATEWAY_ENV_FILE}" >/dev/null
  fi
  sudo chmod 0600 "${GATEWAY_ENV_FILE}"
}

install_unit() {
  log "Installing systemd unit"
  ensure_gateway_env_root
  sudo install -m 0644 "${UNIT_SRC}" "${UNIT_DST}"
  sudo systemctl daemon-reload
  sudo systemctl enable docker-model-gateway.service
}

start_traefik() {
  log "Validating and starting Traefik (creates ${BRIDGE_NET})"
  compose config >/dev/null
  compose up -d traefik

  local i
  for i in $(seq 1 30); do
    if docker network inspect "${BRIDGE_NET}" >/dev/null 2>&1 \
      && ip -4 addr show "${BRIDGE_IFACE}" 2>/dev/null | grep -q "${BRIDGE_IP}"; then
      log "Bridge ${BRIDGE_NET} ready on ${BRIDGE_IFACE} (${BRIDGE_IP})"
      return 0
    fi
    sleep 1
  done
  die "bridge ${BRIDGE_NET}/${BRIDGE_IFACE} with ${BRIDGE_IP} not ready"
}

provision_models() {
  log "Starting Ollama and pulling qwen3.5:2b"
  compose up -d ollama
  compose run --rm ollama-pull-qwen

  log "Provisioning MedGemma via Docker Model Runner (Compose models:)"
  compose run --rm medgemma-provision
}

restart_gateway() {
  log "Restarting docker-model-gateway"
  install_unit
  sudo systemctl restart docker-model-gateway.service
  sleep 2
  sudo systemctl --no-pager --full status docker-model-gateway.service || true
}

smoke_tests() {
  log "Smoke tests"
  local base="https://${MODEL_API_FQDN}/v1"

  log "Auth deny (no key)"
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' \
    -X POST "${base}/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3.5:2b","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' \
    || true)"
  [[ "${code}" != "200" ]] || die "expected auth failure without key, got ${code}"

  log "Auth deny (bad key)"
  code="$(curl -sk -o /dev/null -w '%{http_code}' \
    -X POST "${base}/chat/completions" \
    -H 'Content-Type: application/json' \
    -H 'Authorization: Bearer definitely-not-the-key' \
    -d '{"model":"qwen3.5:2b","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' \
    || true)"
  [[ "${code}" != "200" ]] || die "expected auth failure with bad key, got ${code}"

  log "Chat completion: qwen3.5:2b"
  curl -skf -X POST "${base}/chat/completions" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${GATEWAY_API_KEY}" \
    -d '{"model":"qwen3.5:2b","messages":[{"role":"user","content":"Say hi in one word."}],"max_tokens":16}' \
    | head -c 500
  printf '\n'

  log "Chat completion: google/medgemma-1.5-4b-it (may be slow on first load)"
  curl -skf -X POST "${base}/chat/completions" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${GATEWAY_API_KEY}" \
    -d '{"model":"google/medgemma-1.5-4b-it","messages":[{"role":"user","content":"Say hi in one word."}],"max_tokens":16}' \
    | head -c 500
  printf '\n'

  log "Smoke tests passed"
}

main() {
  load_env
  render_traefik
  start_traefik
  provision_models
  restart_gateway
  smoke_tests
  log "Deploy complete. Endpoint: https://${MODEL_API_FQDN}/v1"
}

main "$@"
