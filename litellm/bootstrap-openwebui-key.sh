#!/bin/sh
# Create the LiteLLM virtual key used by Open WebUI.
# Value comes from LITELLM_OPENWEBUI_KEY. Safe to re-run.
set -eu

base=http://litellm:4000

: "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY is required}"
: "${LITELLM_OPENWEBUI_KEY:?LITELLM_OPENWEBUI_KEY is required}"

if curl --fail --silent --show-error \
  --header "Authorization: Bearer ${LITELLM_OPENWEBUI_KEY}" \
  "${base}/key/info" >/dev/null 2>&1; then
  echo "openwebui key already present"
  exit 0
fi

curl --fail --silent --show-error \
  --header "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  --header "Content-Type: application/json" \
  --request POST \
  --data "{\"key\":\"${LITELLM_OPENWEBUI_KEY}\",\"key_alias\":\"openwebui\"}" \
  "${base}/key/generate" >/dev/null

echo "created openwebui key"
