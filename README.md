# Docker Model Runner MedGemma Gateway

Serve [MedGemma 1.5 4B IT](https://huggingface.co/google/medgemma-1.5-4b-it) via Docker Model Runner’s **vLLM** backend, with API-key auth on **`docker model gateway`** and **HTTPS** via Traefik. Model settings live in Compose YAML; auth lives in gateway YAML.

Replaces the standalone vLLM + Traefik Bearer stack in [n8n-environments medgemma](https://github.com/uwcirg/n8n-environments/tree/main/base/medgemma).

## Prerequisites

- Docker Compose v2.38+ with Compose **models** support
- Docker Model Runner with vLLM (one-time on the host):

  ```bash
  docker model install-runner --backend vllm --gpu cuda
  ```

- Traefik on the external Docker network `external_web` (same pattern as [embedhw-environments extras](https://github.com/uwcirg/embedhw-environments/tree/main/extras))
- NVIDIA GPU + CUDA (vLLM)
- Hugging Face account with MedGemma license accepted and a token for the gated model

## Setup

1. Copy env template and edit:

   ```bash
   cp .env.example .env
   ```

   Set `COMPOSE_PROJECT_NAME`, `BASE_DOMAIN`, `OAI_API_KEY`, and `HUGGING_FACE_HUB_TOKEN`.

2. Export the HF token for model pull (Compose / DMR):

   ```bash
   set -a && source .env && set +a
   ```

3. Start the model (Compose provisions `hf.co/google/medgemma-1.5-4b-it` from [`compose.medgemma.yml`](compose.medgemma.yml)) and the HTTPS proxy:

   ```bash
   docker compose -f compose.medgemma.yml -f compose.gateway-traefik.yml up -d
   ```

4. Start the gateway on the host (loads [`gateway.medgemma.yaml`](gateway.medgemma.yaml)):

   ```bash
   docker model gateway --config gateway.medgemma.yaml
   ```

   Default listen: `0.0.0.0:4000`. On Linux, ensure the process is reachable from the `model-gateway-proxy` container (see `GATEWAY_UPSTREAM` in `.env`).

## Client usage

- **HTTPS base URL:** `https://models.${BASE_DOMAIN}/v1`
- **Model id:** `google/medgemma-1.5-4b-it`
- **Auth:** `Authorization: Bearer ${OAI_API_KEY}` or `x-api-key: ${OAI_API_KEY}`

Example:

```bash
curl "https://models.${BASE_DOMAIN}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${OAI_API_KEY}" \
  -d '{
    "model": "google/medgemma-1.5-4b-it",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

Local gateway (no Traefik):

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${OAI_API_KEY}" \
  -d '{"model": "google/medgemma-1.5-4b-it", "messages": [{"role": "user", "content": "Hello"}]}'
```

## Configuration (YAML only)

| File | Purpose |
|------|---------|
| [`compose.medgemma.yml`](compose.medgemma.yml) | `models.medgemma`: HF id, `context_size: 8192`, `runtime_flags` for `--dtype bfloat16` and `--gpu-memory-utilization 0.90` |
| [`gateway.medgemma.yaml`](gateway.medgemma.yaml) | Routes to DMR vLLM; `master_key` from `OAI_API_KEY` |
| [`compose.gateway-traefik.yml`](compose.gateway-traefik.yml) | Socat + Traefik TLS on `models.${BASE_DOMAIN}` (no Traefik auth) |

Do **not** use `docker model configure` for routine deploys; change the Compose or gateway YAML and redeploy.

## Architecture

```text
Client → Traefik (TLS) → model-gateway-proxy (socat) → docker model gateway :4000
                                                              ↓
                                                    DMR /engines/vllm → MedGemma
```
