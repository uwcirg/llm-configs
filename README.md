# llm-configs

GitOps Compose stack for shared LLM access on one MIG slice of an NVIDIA H200. Researchers use a chat UI or an OpenAI-compatible API. They do not get a shell on the host.

A systemd timer on the host runs `git fetch` and `git reset --hard origin/main`, then `docker compose pull` and `docker compose up -d`. There is no webhook and no push-to-deploy workflow.

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

## PoC only — replace before production

This checkout favors a working default over hardening:

- Postgres superuser is `postgres` / `postgres`.
- Traefik dashboard Basic Auth is `admin` / `admin`.
- LiteLLM UI user is `admin`. The password is the master key, default `sk-admin-master-key-change-me`.
- One shared LiteLLM virtual key (`sk-researcher-key-change-me`) authenticates every Open WebUI chat. Direct API callers can be given their own keys later.
- Open WebUI passwords are `admin`, `researcher`, and `user`.
- `LITELLM_SALT_KEY` defaults to `sk-salt-change-me`. Do not change it after the database exists; stored secrets cannot be decrypted with a new salt.
- Nothing here restricts SSH or other host ports.

## What you must set

Everything else has a default in [`docker-compose.yml`](docker-compose.yml). Copy the example env file and set two values:

```bash
cd /opt/llm-configs
cp .env.example .env
```

| Variable | Example | Purpose |
|----------|---------|---------|
| `BASE_DOMAIN` | `example.org` | Zone for the three public names below |
| `NVIDIA_VISIBLE_DEVICES` | `MIG-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | The one MIG slice this stack may use |

Optional overrides (Postgres password, Ollama tuning, LiteLLM keys, `ACME_EMAIL`, `WEBUI_SECRET_KEY`) are comments in [`.env.example`](.env.example).

### DNS

Create an A, AAAA, or CNAME for each name, aimed at this host:

- `llm.$BASE_DOMAIN` — Open WebUI
- `models.$BASE_DOMAIN` — LiteLLM
- `traefik-dashboard.$BASE_DOMAIN` — Traefik dashboard

Ports 80 and 443 must be reachable from the Internet. Let's Encrypt uses the HTTP-01 challenge. Traefik redirects other HTTP requests to HTTPS. The account email defaults to `ivanc@uw.edu`.

### MIG device

```bash
nvidia-smi -L
```

A sliced GPU lists a `MIG-…` UUID under the physical GPU. Put that UUID in `NVIDIA_VISIBLE_DEVICES`. Compose passes it to the Ollama container as `NVIDIA_VISIBLE_DEVICES` and as the NVIDIA device reservation, so this project stays on that slice.

The host needs Docker Engine, the Compose plugin, and the NVIDIA container toolkit.

## First boot

Clone this repo to `/opt/llm-configs` (the systemd unit uses that path). Set `.env`, then:

```bash
docker compose up -d
```

Postgres creates databases `litellm` and `openwebui` from [`postgres/init/01-databases.sql`](postgres/init/01-databases.sql) the first time the data volume is empty. A `keycloak` database is left commented for later. Init does not run again on an existing volume.

No Ollama models are pulled for you. Model weights persist in the named volume `ollama-models`.

Ollama tuning defaults, overridable from `.env`:

- `OLLAMA_MAX_LOADED_MODELS=2`
- `OLLAMA_NUM_PARALLEL=2`
- `OLLAMA_MAX_QUEUE=512`
- `OLLAMA_KEEP_ALIVE=10m`
- `OLLAMA_FLASH_ATTENTION=1`

## Accounts

Open WebUI logins are email addresses. Signup is disabled.

| Login | Password | Role |
|-------|----------|------|
| `admin@$BASE_DOMAIN` | `admin` | Admin: users, and model pull |
| `researcher@$BASE_DOMAIN` | `researcher` | Standard user |
| `user@$BASE_DOMAIN` | `user` | Second standard user, for multi-user checks |

The admin account pulls models in **Admin Settings → Models → Pull a model from Ollama.com**. That request goes straight to the Ollama API. Bare Ollama ids are hidden from the chat picker so inference does not skip the proxy. After a pull, chat (and `GET /v1/models`) shows the model as `ollama/<tag>`, for example `ollama/llama3.2:latest`. Those calls go to LiteLLM, which forwards to Ollama and records spend on the shared researcher key.

Direct REST uses the same pre-created key (`key_alias` `researcher`). It is not budget- or rate-limited. Further people who call the API themselves get a key from the LiteLLM admin UI at `https://models.$BASE_DOMAIN/ui` (user `admin`, password = `LITELLM_MASTER_KEY`). The `user` account does not have a virtual key until you create one there.

```bash
curl "https://models.${BASE_DOMAIN}/v1/chat/completions" \
  -H "Authorization: Bearer ${LITELLM_RESEARCHER_KEY:-sk-researcher-key-change-me}" \
  -H "Content-Type: application/json" \
  -d '{"model":"ollama/llama3.2","messages":[{"role":"user","content":"Hello"}]}'
```

The Traefik dashboard is `https://traefik-dashboard.$BASE_DOMAIN` with Basic Auth `admin` / `admin`.

## systemd timer

The timer tracks `origin/main`. Merge this branch to `main` before enabling it, and keep a remote named `origin`. `.env` is gitignored, so a reset does not delete it.

If the clone is not `/opt/llm-configs`, edit `WorkingDirectory` and `ExecStart` in [`deploy/llm-gitops.service`](deploy/llm-gitops.service) first.

```bash
sudo cp deploy/llm-gitops.service deploy/llm-gitops.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now llm-gitops.timer
```

The timer waits 2 minutes after boot, then runs 5 minutes after each successful start (`OnUnitActiveSec=5min`). Logs go to the journal and to `/var/log/llm-gitops.log`.

```bash
systemctl list-timers llm-gitops.timer
journalctl -u llm-gitops.service
```

## Rotating the PoC passwords

- **Postgres.** Set `POSTGRES_PASSWORD` (and `POSTGRES_USER` if you change that too). Both `DATABASE_URL`s in Compose use those same defaults, and the init SQL does not contain the password. Changing the variable does not alter a database that already exists. On a live volume, `ALTER USER postgres WITH PASSWORD '…'` inside the container, then recreate the app containers. To start over, remove the `postgres-data` volume (that deletes chat history and LiteLLM keys).
- **Open WebUI.** Change passwords in the admin UI. `WEBUI_ADMIN_PASSWORD` is applied only when the database has no users. `WEBUI_SECRET_KEY` can be rotated; existing sessions stop working.
- **LiteLLM master key.** Change `LITELLM_MASTER_KEY` and recreate the LiteLLM container. Leave `LITELLM_SALT_KEY` alone once the database exists. Replace `LITELLM_RESEARCHER_KEY` by creating a new key in the admin UI (or deleting the old alias and letting [`litellm/bootstrap-keys.sh`](litellm/bootstrap-keys.sh) run again) and point Open WebUI's `OPENAI_API_KEY` at it.
- **Traefik dashboard.** Generate a new apr1 hash (`openssl passwd -apr1`) and replace the `dashboard-auth` label. In the Compose file write each `$` as `$$`.

## Not in this iteration

- No OIDC or Keycloak yet. Commented placeholders are on the Open WebUI service and in [`litellm/config.yaml`](litellm/config.yaml). The Postgres init script has a commented `keycloak` database.
- No vLLM. [`litellm/config.yaml`](litellm/config.yaml) has a commented `vllm/*` model block for a later service.
- No usage guardrails beyond LiteLLM's default per-key accounting. `max_budget`, `rpm_limit`, and `tpm_limit` are left unset; the bootstrap script says where to add them.
- No firewall rules for SSH or other host ports.
