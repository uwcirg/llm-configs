# LLM configs

Compose and gateway configs for local LLM services behind a shared OpenAI-compatible API. Models can use different runtimes (Docker Model Runner / vLLM, Ollama, and others). Settings live in YAML; HTTPS is optional via Traefik.

## Layout

| Path | Purpose |
|------|---------|
| [`gateway.yaml`](gateway.yaml) | Shared `docker model gateway` config: API key + `model_list` routes |
| [`compose.gateway-traefik.yml`](compose.gateway-traefik.yml) | Shared Traefik TLS proxy to the host gateway (`models.${BASE_DOMAIN}`) |
| [`models/<name>/compose.yml`](models/) | Per-model Compose (pull/runtime for that backend) |

Auth is enforced by the gateway (`OAI_API_KEY` as Bearer or `x-api-key`). Traefik terminates TLS only.

## Prerequisites

- Docker Compose v2.38+ (for Compose `models:` when using DMR)
- Traefik on Docker network `external_web` if using HTTPS
- Runtime-specific host setup (e.g. DMR + vLLM, or Ollama)

## Setup

1. Copy and edit env:

   ```bash
   cp .env.example .env
   ```

2. Start the model(s) you need, plus the HTTPS overlay if desired:

   ```bash
   docker compose -f models/medgemma/compose.yml -f compose.gateway-traefik.yml up -d
   ```

3. Start the shared gateway on the host:

   ```bash
   set -a && source .env && set +a
   docker model gateway --config gateway.yaml
   ```

   Default listen: `0.0.0.0:4000`. On Linux, ensure it is reachable from `model-gateway-proxy` (`GATEWAY_UPSTREAM`).

## Client usage

- **HTTPS:** `https://models.${BASE_DOMAIN}/v1`
- **Local:** `http://localhost:4000/v1`
- **Auth:** `Authorization: Bearer ${OAI_API_KEY}` or `x-api-key: ${OAI_API_KEY}`
- **Model id:** the `model_name` from [`gateway.yaml`](gateway.yaml)

```bash
curl "https://models.${BASE_DOMAIN}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${OAI_API_KEY}" \
  -d '{
    "model": "google/medgemma-1.5-4b-it",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

## Adding a model

1. Add `models/<name>/compose.yml` for that runtime (DMR `models:`, Ollama service, etc.).
2. Append a `model_list` entry in [`gateway.yaml`](gateway.yaml) pointing at the upstream (`docker_model_runner`, `ollama`, `vllm`, …).
3. Document any env vars (tokens, domains) in [`.env.example`](.env.example).

Prefer YAML over `docker model configure` for routine deploys.

## Models

| Model | Runtime | Compose |
|-------|---------|---------|
| `google/medgemma-1.5-4b-it` | DMR / vLLM | [`models/medgemma/compose.yml`](models/medgemma/compose.yml) |

## Architecture

```text
Client → Traefik (TLS) → model-gateway-proxy (socat) → docker model gateway :4000
                                                              ↓
                                              runtime backends (DMR, Ollama, …)
```
