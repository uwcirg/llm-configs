# llm-configs

GitOps Compose stack for shared LLM access on one MIG slice of an NVIDIA H200. Researchers use a chat UI or an OpenAI-compatible API. They do not get a shell on the host.

A systemd timer on the host runs `git fetch` and `git reset --hard origin/main`, then `docker compose pull` and `docker compose up --detach`. There is no webhook and no push-to-deploy workflow.

```text
Browser / SDK
  → Traefik :443
      llm.<BASE_DOMAIN>    → Open WebUI
      models.<BASE_DOMAIN> → LiteLLM (API and admin UI)
  Open WebUI --chat--> LiteLLM --ollama_chat--> Ollama (one MIG device)
  Open WebUI --pull--> Ollama
  LiteLLM and Open WebUI → Postgres
```

Ollama and Postgres publish no host ports. Only Traefik listens on 80 and 443.

LiteLLM trusts Traefik’s `X-Forwarded-*` headers from any peer (PoC) so spend logs show the client IP from `X-Forwarded-For` instead of the Traefik container address. `PROXY_BASE_URL` is set to `https://models.$BASE_DOMAIN`.

## PoC only — replace before production

This checkout favors a working default over hardening:

- Postgres superuser is `postgres` with a hard-to-guess default password set in Compose (`p9Kx2mQ7vL4nR8wT`). Still plaintext in git.
- Traefik dashboard Basic Auth is `admin` / `admin`.
- LiteLLM UI user is `admin`. The password is `LITELLM_MASTER_KEY` from `litellm.env`.
- One shared LiteLLM virtual key (`LITELLM_RESEARCHER_KEY`) authenticates every Open WebUI chat. Direct API callers can be given their own keys later.
- Open WebUI passwords are `admin`, `researcher`, and `user`.
- Do not change `LITELLM_SALT_KEY` after the database exists; stored secrets cannot be decrypted with a new salt.
- Nothing here restricts SSH or other host ports.

## What you must set

Host-level values live in the project `.env` (Compose interpolation for DNS and the MIG device). Service-specific settings live in per-service env files.

```bash
cd /opt/llm-configs
cp .env.example .env
cp ollama.env.example ollama.env
cp litellm.env.example litellm.env
cp openwebui.env.example openwebui.env
# edit .env: set BASE_DOMAIN and NVIDIA_VISIBLE_DEVICES
```

| Variable | Example | Purpose |
|----------|---------|---------|
| `BASE_DOMAIN` | `example.org` | Zone for the three public names below |
| `NVIDIA_VISIBLE_DEVICES` | `MIG-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | The one MIG slice this stack may use |

Optional overrides:

- Ollama tuning → [`ollama.env.example`](ollama.env.example)
- LiteLLM keys and `DATABASE_URL` → [`litellm.env.example`](litellm.env.example)
- Open WebUI secret, OpenAI key, and `DATABASE_URL` → [`openwebui.env.example`](openwebui.env.example)
- `ACME_EMAIL` → comment in [`.env.example`](.env.example)

If you change the Postgres password in Compose, update both app `DATABASE_URL`s to match. Keep Open WebUI’s `OPENAI_API_KEY` aligned with `LITELLM_RESEARCHER_KEY`.

### DNS

Create an A, AAAA, or CNAME for each name, aimed at this host:

- `llm.$BASE_DOMAIN` — Open WebUI
- `models.$BASE_DOMAIN` — LiteLLM
- `traefik-dashboard.$BASE_DOMAIN` — Traefik dashboard

Ports 80 and 443 must be reachable from the Internet. Let's Encrypt uses the HTTP-01 challenge. Traefik redirects other HTTP requests to HTTPS. The account email defaults to `cirg-adm@uw.edu`.

### MIG device

```bash
nvidia-smi --list-gpus
```

A sliced GPU lists a `MIG-…` UUID under the physical GPU. Put that UUID in `NVIDIA_VISIBLE_DEVICES`. Compose passes it to the Ollama container as `NVIDIA_VISIBLE_DEVICES` and as the NVIDIA device reservation, so this project stays on that slice.

The host needs Docker Engine, the Compose plugin, and the NVIDIA container toolkit.

## First boot

Clone this repo to `/opt/llm-configs` (the systemd unit uses that path). Copy the env examples above, set `.env`, then:

```bash
docker compose up --detach
```

Postgres creates databases `litellm` and `openwebui` from [`postgres/init/01-databases.sql`](postgres/init/01-databases.sql) the first time the data volume is empty. A `keycloak` database is left commented for later. Init does not run again on an existing volume.

No Ollama models are pulled for you. Model weights persist in the named volume `ollama-models`.

Ollama tuning defaults live in [`ollama.env.example`](ollama.env.example) (`OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_NUM_PARALLEL`, `OLLAMA_MAX_QUEUE`, `OLLAMA_KEEP_ALIVE`, `OLLAMA_FLASH_ATTENTION`).

## Accounts

PoC credentials by service. Open WebUI signup is disabled.

| Service | Where | Login / key | Password / secret | Purpose |
|---------|-------|-------------|-------------------|---------|
| Open WebUI | `https://llm.$BASE_DOMAIN` | `admin@localhost` | `admin` | Chat UI admin (users, model pull) |
| Open WebUI | same | `researcher@localhost` | `researcher` | Chat UI standard user |
| Open WebUI | same | `user@localhost` | `user` | Second chat UI user |
| LiteLLM | `https://models.$BASE_DOMAIN/ui` | `admin` | `LITELLM_MASTER_KEY` | Management UI (keys, spend) |
| LiteLLM | `https://models.$BASE_DOMAIN` API | Bearer `LITELLM_RESEARCHER_KEY` | — | Direct OpenAI-compatible REST; also the key Open WebUI uses for chat |
| Ollama | internal Docker network only | — | — | No public login. Model pull goes through Open WebUI admin; inference goes through LiteLLM |

Open WebUI accounts are created only when its user table is empty. An existing `postgres-data` volume keeps the previous `admin@$BASE_DOMAIN` accounts until that volume is recreated.

The Open WebUI admin pulls models in **Admin Settings → Models → Pull a model from Ollama.com**. That request goes straight to Ollama. Bare Ollama ids are hidden from the chat picker so inference does not skip the proxy. After a pull, chat (and `GET /v1/models`) shows the model as `ollama/<tag>`, for example `ollama/llama3.2:latest`. Those calls go to LiteLLM, which forwards to Ollama and records spend on the shared researcher key.

The researcher virtual key (`key_alias` `researcher`) is not budget- or rate-limited. Further people who call the API themselves get a key from the LiteLLM management UI. The Open WebUI `user` account does not have its own LiteLLM key until you create one there.

```bash
curl "https://models.${BASE_DOMAIN}/v1/chat/completions" \
  --header "Authorization: Bearer ${LITELLM_RESEARCHER_KEY}" \
  --header "Content-Type: application/json" \
  --data '{"model":"ollama/llama3.2","messages":[{"role":"user","content":"Hello"}]}'
```

The Traefik dashboard is `https://traefik-dashboard.$BASE_DOMAIN` with Basic Auth `admin` / `admin`.

## systemd timer

The timer tracks `origin/main`. Merge this branch to `main` before enabling it, and keep a remote named `origin`. `.env` and the service `*.env` files are gitignored, so a reset does not delete them.

If the clone is not `/opt/llm-configs`, edit `WorkingDirectory` and `ExecStart` in [`deploy/llm-gitops.service`](deploy/llm-gitops.service) first.

```bash
sudo cp deploy/llm-gitops.service deploy/llm-gitops.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now llm-gitops.timer
```

The timer waits 2 minutes after boot, then runs 5 minutes after each successful start (`OnUnitActiveSec=5min`). Logs go to the journal and to `/var/log/llm-gitops.log`.

```bash
systemctl list-timers llm-gitops.timer
journalctl --unit llm-gitops.service
```

## Rotating the PoC passwords

- **Postgres.** Change `POSTGRES_PASSWORD` in Compose (or set it in the project `.env`). Update `DATABASE_URL` in both `litellm.env` and `openwebui.env`. The init SQL does not contain the password. Changing the variable does not alter a database that already exists. On a live volume, `ALTER USER postgres WITH PASSWORD '…'` inside the container, then recreate the app containers. To start over, remove the `postgres-data` volume (that deletes chat history and LiteLLM keys).
- **Open WebUI.** Change passwords in the admin UI. `WEBUI_ADMIN_PASSWORD` is applied only when the database has no users. Rotate `WEBUI_SECRET_KEY` in `openwebui.env`; existing sessions stop working.
- **LiteLLM master key.** Change `LITELLM_MASTER_KEY` in `litellm.env` and recreate the LiteLLM container. Leave `LITELLM_SALT_KEY` alone once the database exists. Replace `LITELLM_RESEARCHER_KEY` by creating a new key in the admin UI (or deleting the old alias and letting [`litellm/bootstrap-keys.sh`](litellm/bootstrap-keys.sh) run again) and set the same value as `OPENAI_API_KEY` in `openwebui.env`.
- **Traefik dashboard.** Generate a new apr1 hash (`openssl passwd --apr1`) and replace the `dashboard-auth` label. In the Compose file write each `$` as `$$`.

## Not in this iteration

- No OIDC or Keycloak yet. Commented placeholders are on the Open WebUI service and in [`litellm/config.yaml`](litellm/config.yaml). The Postgres init script has a commented `keycloak` database.
- No vLLM. [`litellm/config.yaml`](litellm/config.yaml) has a commented `vllm/*` model block for a later service.
- No usage guardrails beyond LiteLLM's default per-key accounting. `max_budget`, `rpm_limit`, and `tpm_limit` are left unset; the bootstrap script says where to add them.
- No firewall rules for SSH or other host ports.
