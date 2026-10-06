#!/usr/bin/env bash
set +x
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

USAGE="Install Praxis gateways and switch the provisioned OGX deployment into Praxis mode."

parse_args "$@"
require_tools oc
resolve_context
preflight

setup_workdir Installation
MODEL="$(yq -er '.model' "${FILES}/versions.yaml")"
VERSION="$(yq -er '.grid.version' "${FILES}/versions.yaml")"
IMAGE="$(yq -er '.praxis.image' "${FILES}/versions.yaml")"
[[ "$MODEL" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "Confirm the selected OpenAI model in files/versions.yaml"

cr="$(k -n "$NAMESPACE" get ogxserver ogx-distribution -o json)"
if ! jq -e '.spec.overrideConfig == null and
  (.spec.praxisMode.migrationJob == null or .spec.praxisMode.migrationJob.enabled == false)' <<< "$cr" >/dev/null; then
  die "OGX has an override configuration or migration job; confirm its handling before switching modes"
fi
OGX_PORT="$(jq -r '.spec.network.port // 8321' <<< "$cr")"
[[ "$OGX_PORT" =~ ^[0-9]+$ ]] && ((OGX_PORT > 0 && OGX_PORT <= 65535)) || die "Invalid OGX API port"
unset cr
OGX_ENDPOINT="ogx-distribution-service.${NAMESPACE}.svc.cluster.local:${OGX_PORT}"
OGX_URL="http://${OGX_ENDPOINT}"
if ! k -n "$NAMESPACE" get service ogx-distribution-service -o json | jq -e --argjson port "$OGX_PORT" \
  '.spec.type == "ClusterIP" and any(.spec.ports[]; .port == $port)' >/dev/null; then
  die "OGX Service differs from the internal Showroom service; confirm its configuration"
fi
if ! k -n grid-system get inferenceprovider openai-mvp-provider -o json | jq -e --arg model "$MODEL" \
  '.spec.endpoint == "https://api.openai.com" and any(.spec.models[]?; .name == $model)' >/dev/null; then
  die "Grid does not register the selected OpenAI model; run prepare.sh on this context"
fi
if ! k -n models-as-a-service get externalmodel praxis-mvp -o json | jq -e --arg model "$MODEL" \
  '.spec.modelName == $model' >/dev/null; then
  die "MaaS does not register the selected OpenAI model; run prepare.sh on this context"
fi
wait_for -n models-as-a-service maassubscription/praxis-mvp --for=jsonpath='{.status.phase}'=Active
wait_for -n openshift-ingress authpolicy/maas-gateway-auth --for=condition=Enforced
rollout grid-system grid-operator
rollout redhat-ai-gateway-infra maas-api

# Refuse to widen the gateway trust boundary through additive, unrelated rules.
k -n grid-system get networkpolicies -o json > "${WORK_DIR}/networkpolicies.json"
python3 - "${WORK_DIR}/networkpolicies.json" <<'PY'
import json, sys
def matches(selector, labels):
    if any(labels.get(k) != v for k, v in selector.get("matchLabels", {}).items()):
        return False
    for expression in selector.get("matchExpressions", []):
        key, operation = expression["key"], expression["operator"]
        present, value = key in labels, labels.get(key)
        values = expression.get("values", [])
        if operation == "In" and (not present or value not in values): return False
        if operation == "NotIn" and present and value in values: return False
        if operation == "Exists" and not present: return False
        if operation == "DoesNotExist" and present: return False
    return True
for policy in json.load(open(sys.argv[1]))["items"]:
    if policy["metadata"]["name"] in ("consumer-gateway", "provider-gateway"):
        continue
    if not policy["spec"].get("ingress"):
        continue
    for role in ("consumer", "provider"):
        labels = {"app.kubernetes.io/name": "praxis-gateway", "app.kubernetes.io/instance": role + "-gateway"}
        if matches(policy["spec"].get("podSelector", {}), labels):
            print("ERROR: An additional NetworkPolicy grants gateway ingress; confirm grid-system policies before installation.", file=sys.stderr)
            sys.exit(1)
PY

for name in consumer-tls provider-tls openai-credential praxis-store; do
  k -n grid-system get secret "$name" -o json | jq '.data' > "${WORK_DIR}/${name}.json"
done
for role in consumer provider; do
  for key in tls.crt tls.key ca.crt; do
    jq -ej --arg key "$key" '.[$key] | select(type == "string" and length > 0) | @base64d' \
      "${WORK_DIR}/${role}-tls.json" > "${WORK_DIR}/${role}-${key}"
  done
  openssl verify -CAfile "${WORK_DIR}/${role}-ca.crt" "${WORK_DIR}/${role}-tls.crt" >/dev/null 2>&1 \
    || die "Gateway TLS is invalid or expired; rerun prepare.sh after renewal"
done
cmp -s "${WORK_DIR}/consumer-ca.crt" "${WORK_DIR}/provider-ca.crt" || die "Gateway CA certificates disagree"
jq -e '.token | type == "string" and length > 0' "${WORK_DIR}/openai-credential.json" >/dev/null
jq -e 'all([.POSTGRES_USER, .POSTGRES_PASSWORD][]; type == "string" and length > 0)' "${WORK_DIR}/praxis-store.json" >/dev/null

archive="${WORK_DIR}/praxis-gateway-${VERSION}.tgz"
release_url="$(yq '.grid.releaseUrl' "${FILES}/versions.yaml")"
expected="$(yq '.grid.gatewaySha256' "${FILES}/versions.yaml")"
curl -fsSL --connect-timeout 15 --max-time 120 "${release_url}/praxis-gateway-${VERSION}.tgz" -o "$archive" 2>/dev/null
python3 - "$archive" "$expected" <<'PY'
import hashlib, pathlib, sys
sys.exit(0 if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() == sys.argv[2] else 1)
PY

grid_candidate() {
  k -n grid-system get configmap grid-overlay-praxis-mvp-consumer-gateway -o json \
    | jq -er '.data["routing-config.json"]' | jq -er --arg model "$MODEL" '
      [.candidates[] | select(.kind == "inference_model" and .name == $model and
        .cluster == "openai-mvp-provider" and .site == "mvp")] |
      select(length == 1) | .[0].stable_id | select(type == "string" and length > 0)
    '
}
CANDIDATE=""
if poll_until 120 grid_candidate; then
  CANDIDATE="$POLL_OUTPUT"
fi
[[ "$CANDIDATE" =~ ^[a-zA-Z0-9_.:-]+$ ]] || die "Grid overlay did not publish a unique selected-model candidate; check prepare.sh"

python3 - "$FILES" "$WORK_DIR" "$MODEL" "$CANDIDATE" "$OGX_ENDPOINT" "$OGX_URL" <<'PY'
import pathlib, sys
source, target = map(pathlib.Path, sys.argv[1:3])
text = (source / "provider-praxis.yaml").read_text()
for token, value in zip(("__MODEL__", "__CANDIDATE__", "__OGX_ENDPOINT__", "__OGX_URL__"), sys.argv[3:]):
    text = text.replace(token, value)
(target / "provider-praxis.yaml").write_text(text)
PY
MODEL="$MODEL" yq '.global.pdp[0].data.model_refs = {strenv(MODEL): "praxis-mvp"}' \
  "${FILES}/model-policy.yaml" > "${WORK_DIR}/model-policy.yaml"
PORT="$OGX_PORT" yq '(.spec.ingress[0].ports[0].portNumber.port, .spec.ingress[1].ports[0].portNumber.port) = env(PORT)' \
  "${FILES}/ogx-adminnetworkpolicy.yaml" > "${WORK_DIR}/ogx-adminnetworkpolicy.yaml"
for role in consumer provider; do
  config="${FILES}/consumer-praxis.yaml"
  [[ "$role" != provider ]] || config="${WORK_DIR}/provider-praxis.yaml"
  inputs=("$config" "${WORK_DIR}/${role}-tls.json")
  if [[ "$role" == consumer ]]; then
    inputs+=("${WORK_DIR}/model-policy.yaml")
  else
    inputs+=("${WORK_DIR}/openai-credential.json" "${WORK_DIR}/praxis-store.json")
  fi
  digest="$(python3 - "${inputs[@]}" <<'PY'
import hashlib, json, pathlib, sys
digest = hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes())
for name in sys.argv[2:]:
    path = pathlib.Path(name)
    data = json.dumps(json.loads(path.read_text()), sort_keys=True).encode() if path.suffix == ".json" else path.read_bytes()
    digest.update(data)
print(digest.hexdigest())
PY
  )"
  HASH="$digest" yq '.podAnnotations."showroom-praxis/config-hash" = strenv(HASH)' \
    "${FILES}/${role}-gateway.yaml" > "${WORK_DIR}/${role}-gateway.yaml"
  helm template "${role}-gateway" "$archive" -n grid-system -f "${WORK_DIR}/${role}-gateway.yaml" \
    --set-string "image.repository=${IMAGE%:*},image.tag=${IMAGE##*:},image.digest=" >/dev/null 2>&1
done
k apply --dry-run=server -f "${WORK_DIR}/ogx-adminnetworkpolicy.yaml" >/dev/null
k -n "$NAMESPACE" patch ogxserver ogx-distribution --type=merge --patch-file "${FILES}/ogx-patch.yaml" --dry-run=server >/dev/null
k apply --dry-run=server -f "${FILES}/auth.yaml" >/dev/null

old_route="$(k -n "$NAMESPACE" get route ogx-distribution --ignore-not-found -o json)"
if [[ -n "$old_route" ]] && ! jq -e '
  .metadata.annotations["meta.helm.sh/release-name"] == "ogx-rhoai" and
  .spec.to.name == "ogx-distribution-service"
' <<< "$old_route" >/dev/null; then
  die "The OGX public Route is not the Showroom Helm Route; confirm external exposure before installation"
fi
public_host="$(k -n openshift-ingress get route praxis-mvp --ignore-not-found -o json | jq -r '.spec.host // empty')"
yq -o=json '.' "${FILES}/auth.yaml" | jq --arg host "$public_host" '
  if .kind == "Route" and $host != "" then .spec.host = $host else . end
' > "${WORK_DIR}/auth.json"

echo "Installing Praxis mode on context: $CONTEXT"
echo "Applies OGX ingress isolation and trusted-header authentication, rolls gateways, and replaces public OGX access with MaaS-authenticated Praxis access."

# Keep default-deny isolation if Helm removes a legacy chart-owned policy.
yq 'select(.metadata.name == "praxis-gateway-isolation")' "${FILES}/gateway-networkpolicies.yaml" | apply
# Close the consumer before changing the frontend or gateway configuration.
yq 'select(.metadata.name == "consumer-gateway") | .spec.ingress = []' "${FILES}/gateway-networkpolicies.yaml" | apply
yq 'select(.metadata.name == "provider-gateway")' "${FILES}/gateway-networkpolicies.yaml" | apply
echo "Applying OGX ingress isolation and waiting for CNI readiness..."
apply < "${WORK_DIR}/ogx-adminnetworkpolicy.yaml"
poll_until 120 adminnetworkpolicy_ready praxis-mvp-ogx \
  || die "AdminNetworkPolicy is not ready; consumer remains closed"
if [[ -n "$old_route" ]]; then
  k -n "$NAMESPACE" delete route ogx-distribution --ignore-not-found >/dev/null
fi
echo "Waiting for OGX Praxis-mode configuration and deployment (timeout $TIMEOUT)..."
generation="$(k -n "$NAMESPACE" patch ogxserver ogx-distribution --type=merge \
  --patch-file "${FILES}/ogx-patch.yaml" -o json | jq -r '.metadata.generation')"
ogx_reconciled() {
  k -n "$NAMESPACE" get ogxserver ogx-distribution -o json | jq -e --argjson generation "$1" '
    .status.phase == "Ready" and (.status.configGeneration.observedGeneration // 0) >= $generation
  ' >/dev/null
}
poll_until 900 ogx_reconciled "$generation" \
  || die "OGX operator did not reconcile Praxis mode; consumer remains closed"
rollout "$NAMESPACE" ogx-distribution
config_name="$(k -n "$NAMESPACE" get ogxserver ogx-distribution -o jsonpath='{.status.configGeneration.configMapName}')"
if ! k -n "$NAMESPACE" get configmap "$config_name" -o json | jq -er '.data["config.yaml"]' \
  | yq -o=json '.' | jq -e '
    .server.auth.provider_config.type == "upstream_header" and
    .server.auth.provider_config.principal_header == "x-user-id" and
    .server.auth.provider_config.tenant_header == "x-tenant-id" and
    .server.tenancy.mode == "multi" and .storage.stores.vector_stores.backend != null and
    all(.apis[]; . != "responses" and . != "conversations")
  ' >/dev/null; then
  die "OGX runtime configuration does not implement the required identity/storage settings; consumer remains closed"
fi

k -n grid-system create configmap provider-praxis-config --from-file=praxis.yaml="${WORK_DIR}/provider-praxis.yaml" --dry-run=client -o yaml | apply
k -n grid-system create configmap consumer-praxis-config --from-file=praxis.yaml="${FILES}/consumer-praxis.yaml" --dry-run=client -o yaml | apply
k -n grid-system create secret generic praxis-model-policy --from-file=policy.yaml="${WORK_DIR}/model-policy.yaml" --dry-run=client -o yaml \
  | k apply --server-side --force-conflicts --field-manager=showroom-praxis -f - >/dev/null
apply < "${FILES}/provider-state.yaml"
for role in provider consumer; do
  echo "Installing $role gateway and waiting for readiness (timeout $TIMEOUT)..."
  helm upgrade --install "${role}-gateway" "$archive" --kube-context "$CONTEXT" -n grid-system \
    --reuse-values -f "${WORK_DIR}/${role}-gateway.yaml" \
    --set-string "image.repository=${IMAGE%:*},image.tag=${IMAGE##*:},image.digest=" \
    --wait --timeout="$TIMEOUT" >/dev/null 2>&1
  rollout grid-system "${role}-gateway"
done

# Publish only after the HTTPRoute's Authorino policy is enforced.
echo "Waiting for frontend routing and authentication enforcement (timeout $TIMEOUT)..."
jq 'select(.kind == "AuthPolicy")' "${WORK_DIR}/auth.json" | apply
jq 'select(.kind == "Gateway" or .kind == "HTTPRoute")' "${WORK_DIR}/auth.json" | apply
wait_for -n openshift-ingress gateway/praxis-mvp --for=condition=Programmed
wait_for -n grid-system authpolicy/praxis-mvp --for=condition=Enforced
apply < "${FILES}/gateway-networkpolicies.yaml"
jq 'select(.kind == "Route")' "${WORK_DIR}/auth.json" | apply
host="$(k -n openshift-ingress get route praxis-mvp -o jsonpath='{.spec.host}')"
[[ "$host" =~ ^[a-zA-Z0-9.-]+$ ]] || die "Praxis Route has no valid public hostname"
echo "Praxis endpoint: https://$host"
echo "Installation complete. Clients use this endpoint with MaaS API keys and model $MODEL."
