#!/bin/sh
# Create the standard Open WebUI users after the admin account exists.
# Passwords are the PoC literals (researcher / user). Safe to re-run.
set -eu

base=http://openwebui:8080

signin() {
  curl -fsS "${base}/api/v1/auths/signin" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$2\"}"
}

token=$(signin "$WEBUI_ADMIN_EMAIL" "$WEBUI_ADMIN_PASSWORD" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
if [ -z "$token" ]; then
  echo "admin sign-in did not return a token" >&2
  exit 1
fi

add_user() {
  email=$1
  password=$2
  name=$3
  if signin "$email" "$password" >/dev/null 2>&1; then
    echo "${name} already present"
    return 0
  fi
  curl -fsS "${base}/api/v1/auths/add" \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"${password}\",\"name\":\"${name}\",\"role\":\"user\"}" \
    >/dev/null
  echo "created ${name}"
}

add_user "$RESEARCHER_EMAIL" "$RESEARCHER_PASSWORD" "$RESEARCHER_NAME"
add_user "$USER_EMAIL" "$USER_PASSWORD" "$USER_NAME"
