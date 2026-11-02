#!/bin/sh
# Create the researcher virtual key once LiteLLM is healthy. Safe to re-run.
# Budgets and rate limits are omitted on purpose. To tighten later, add
# max_budget, rpm_limit, and/or tpm_limit to the /key/generate JSON body.
set -eu

base=http://litellm:4000
auth="Authorization: Bearer ${LITELLM_MASTER_KEY}"

code=$(curl --silent --show-error --output /tmp/keyinfo --write-out '%{http_code}' \
  "${base}/key/info?key=${LITELLM_RESEARCHER_KEY}" \
  --header "$auth")
if [ "$code" = "200" ]; then
  echo "researcher key already present"
  exit 0
fi

# models omitted: the key may call every configured model, including ones
# pulled later. Add "models": ["ollama/*"] here to restrict it.
code=$(curl --silent --show-error --output /tmp/keygen --write-out '%{http_code}' \
  --request POST "${base}/key/generate" \
  --header "$auth" \
  --header 'Content-Type: application/json' \
  --data "{\"key\":\"${LITELLM_RESEARCHER_KEY}\",\"key_alias\":\"researcher\"}")

if [ "$code" = "200" ]; then
  echo "created researcher key"
  exit 0
fi

if grep --quiet 'already exists' /tmp/keygen; then
  echo "researcher key already present"
  exit 0
fi

cat /tmp/keygen >&2
exit 1
