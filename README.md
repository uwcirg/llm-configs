# llm-configs

GitOps YAML for a shared OpenAI-compatible model API on Ubuntu.

Researchers edit committed YAML, pull on the model VM, and run `./deploy.sh`.
The public entrypoint is `https://<MODEL_API_FQDN>/v1/...`. Traefik terminates
TLS; Docker Model Gateway enforces the API key; backends are Docker Model Runner
and/or Ollama on host loopback.

```text
Client → Traefik (:443) → host gateway 172.30.50.1:4000
                              ├─ Docker Model Runner 127.0.0.1:12434  (MedGemma / vLLM)
                              └─ Ollama                 127.0.0.1:11434  (qwen3.5:2b)
```

## Layout

| Path | Who edits | Purpose |
|------|-----------|---------|
| [`gateway/gateway.yml`](gateway/gateway.yml) | Researchers | Public model aliases + upstream routing |
| [`models/<name>/compose.yml`](models/) | Researchers | How to provision each local model |
| [`compose.yaml`](compose.yaml) | Operators | Traefik + `model_api_net` bridge |
| [`traefik/`](traefik/) | Operators | TLS static config + dynamic router (`MODEL_API_FQDN` via Traefik `env`) |
| [`systemd/docker-model-gateway.service`](systemd/docker-model-gateway.service) | Operators | Host gateway unit (install once) |
| [`deploy.sh`](deploy.sh) | Operators / VM | `compose up` + gateway restart |

Secrets never go in Git. Gateway auth lives in `/etc/docker-model-gateway.env`.

## Configured models

| Client `model` id | Runtime | Provisioning |
|-------------------|---------|--------------|
| `google/medgemma-1.5-4b-it` | Docker Model Runner / vLLM | [`models/medgemma/compose.yml`](models/medgemma/compose.yml) |
| `qwen3.5:2b` | Ollama | [`models/qwen/compose.yml`](models/qwen/compose.yml) |

## Prerequisites (operator, once per VM)

- Ubuntu with [Docker Engine from Docker’s apt repo](https://docs.docker.com/engine/install/ubuntu/) (`docker-ce`), Compose plugin, and `docker-model-plugin`
- Do **not** use Ubuntu’s `docker.io` package for Model Runner
- For MedGemma / vLLM: `docker model install-runner --backend vllm --gpu cuda`
- DNS A record for `MODEL_API_FQDN` pointing at the VM; ports 80 and 443 reachable for HTTP-01
- Host/cloud firewall:
  - Allow TCP 80, 443 from the internet (and SSH from admin sources)
  - Deny external access to TCP 4000, 11434, and 12434
  - Prefer allowing TCP 4000 on host **INPUT** only from `model_api_br` / `172.30.50.0/24`
- Checkout this repo on the VM (example: `/opt/llm-configs`)

## First-time operator setup

```bash
cd /opt/llm-configs   # or your clone path
cp .env.example .env
# edit MODEL_API_FQDN, ACME_EMAIL, HUGGING_FACE_HUB_TOKEN

sudo tee /etc/docker-model-gateway.env >/dev/null <<EOF
GATEWAY_API_KEY=$(openssl rand -hex 32)
LLM_CONFIGS_ROOT=/opt/llm-configs
EOF
sudo chmod 0600 /etc/docker-model-gateway.env

sudo install -m 0644 systemd/docker-model-gateway.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable docker-model-gateway.service

./deploy.sh
```

## Researcher workflow (add or change a model)

1. **Provision YAML** — add or edit `models/<name>/compose.yml`
   - Docker Model Runner: top-level `models:` + a short-lived service that references the model
   - Ollama: service + pull one-shot (see `models/qwen/`)
2. **Gateway alias** — add a matching `model_list` entry in [`gateway/gateway.yml`](gateway/gateway.yml)
   - DMR example: `model: docker_model_runner/<artifact>`, `api_base: http://127.0.0.1:12434/engines/<engine>/v1`
   - Ollama example: `model: ollama/<name:tag>`, `api_base: http://127.0.0.1:11434/v1`
3. Commit and push; on the VM `git pull` and run `./deploy.sh`
4. Call `https://<MODEL_API_FQDN>/v1/chat/completions` with `Authorization: Bearer <GATEWAY_API_KEY>`

Removing a model: delete its `models/` file and `model_list` entry, redeploy. Cached weights are **not** deleted automatically (safe default).

### Files researchers should not change without an operator

- Bridge subnet / `172.30.50.1` (must stay consistent across Compose, Traefik upstream, systemd, firewall)
- Traefik image pin, ACME storage path, published ports
- Binding the gateway to `0.0.0.0` or publishing Ollama / Model Runner publicly

## Client usage

```bash
curl "https://${MODEL_API_FQDN}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${GATEWAY_API_KEY}" \
  -d '{
    "model": "qwen3.5:2b",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

Auth also accepts `x-api-key: <GATEWAY_API_KEY>`.

## Deploy behavior

`./deploy.sh` will:

1. Ensure `letsencrypt/acme.json` exists (mode `0600`)
2. `docker compose up -d --remove-orphans` (Compose loads `.env` / `COMPOSE_FILE`; creates/updates networks and services)
3. `systemctl restart docker-model-gateway`

`ACME_EMAIL` is passed to Traefik via a Compose CLI flag. `MODEL_API_FQDN` is passed as a container env var and read in [`traefik/dynamic/model-api.yml`](traefik/dynamic/model-api.yml) with `{{ env "MODEL_API_FQDN" }}`.

## Rollback

1. `git checkout <previous-good-revision>`
2. `./deploy.sh`
3. Keep `letsencrypt/` (ACME) and model caches; do not delete `model_api_net` while the gateway is bound to `172.30.50.1`

## Secret rotation

1. Put a new `GATEWAY_API_KEY` in `/etc/docker-model-gateway.env` (mode `0600`)
2. `sudo systemctl restart docker-model-gateway` (or `./deploy.sh`)
3. Distribute the new key to clients; old key stops working immediately

## Reboot

Traefik uses `restart: unless-stopped` so Docker recreates the container and bridge.
The gateway unit waits for Docker and refuses to start if `model_api_net` / `172.30.50.1` are missing (`Restart=on-failure` retries). Validate with an actual reboot after first install.
