#!/usr/bin/env bash
#set +x
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

USAGE="Create a one-hour MaaS key, list vector stores and run hello-world inference."

request() {
  local key="$1"
  shift
  printf 'Authorization: Bearer %s\n' "$key" |
    curl --noproxy '*' --fail --silent --show-error --header @- "$@"
}

parse_args "$@"
require_tools oc curl jq
resolve_context

HOST="$(k -n openshift-ingress get route praxis-mvp -o jsonpath='{.spec.host}')" \
  || die "Cannot find the Praxis Route"
[[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || die "Praxis Route has no valid hostname"
PRAXIS_URL="https://${HOST}"

MAAS_HOST="$(k -n openshift-ingress get gateway maas-default-gateway -o jsonpath='{.status.addresses[0].value}')" \
  || die "Cannot find the MaaS gateway address"
[[ "$MAAS_HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || die "MaaS gateway has no valid address"

TOKEN="$(k whoami -t)" || die "Cannot obtain the logged-in user's token"
# The gateway's internal service certificate does not match its external address.
MAAS_API_KEY="$(request "$TOKEN" --insecure --connect-timeout 15 --max-time 60 \
  "https://${MAAS_HOST}/maas-api/v1/api-keys" \
  -H 'Content-Type: application/json' \
  -d '{"name":"praxis-demo","subscription":"praxis-mvp","expiresIn":"1h"}' \
  | jq -er '.key | select(type == "string" and length > 0)' 2>/dev/null)" \
  || die "MaaS API-key creation failed"
unset TOKEN
echo "Created a MaaS key valid for one hour."

echo "Vector stores:"
request "$MAAS_API_KEY" --connect-timeout 15 --max-time 60 \
  "$PRAXIS_URL/v1/vector_stores" | jq .

echo "Hello-world inference:"
request "$MAAS_API_KEY" --connect-timeout 15 --max-time 600 \
  "$PRAXIS_URL/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4.1-mini","messages":[{"role":"user","content":"Say hello world."}],"max_tokens":32}' \
  | jq -er '.choices[0].message.content'
