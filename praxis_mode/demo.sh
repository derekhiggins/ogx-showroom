#!/usr/bin/env bash
#set +x
set -euo pipefail
umask 077

CONTEXT=""

die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  echo "Usage: $0 [--context CONTEXT]"
  echo "Create a one-hour MaaS key, list vector stores and run hello-world inference."
}
k() { oc --context "$CONTEXT" --request-timeout=30s "$@" 2>/dev/null; }
request() {
  local key="$1"
  shift
  printf 'Authorization: Bearer %s\n' "$key" |
    curl --noproxy '*' --fail --silent --show-error --header @- "$@"
}

while (($#)); do
  case "$1" in
    --context)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "--context requires a value"
      CONTEXT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
for tool in oc curl jq; do
  command -v "$tool" >/dev/null || die "$tool is required"
done
if [[ -z "$CONTEXT" ]]; then
  CONTEXT="$(oc config current-context 2>/dev/null)" || die "Pass --context CONTEXT"
fi
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
