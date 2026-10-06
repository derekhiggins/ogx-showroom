#!/usr/bin/env bash
set +x
set -euo pipefail

CONTEXT=""
NAMESPACE=redhat-ods-applications
OGX_NAME=ogx-distribution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0
PENDING=0

usage() {
  echo "Usage: $0 [--context CONTEXT]"
  echo "Read-only prerequisite checks for Praxis mode after ./provision.sh."
}

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pending() { echo "PREPARE: $*"; PENDING=$((PENDING + 1)); }
k() { oc --context "$CONTEXT" --request-timeout=15s "$@" 2>/dev/null; }

while (($#)); do
  case "$1" in
    --context)
      if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        echo "ERROR: --context requires a value" >&2
        exit 1
      fi
      CONTEXT="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

for tool in oc helm jq yq python3 openssl curl uv; do
  command -v "$tool" >/dev/null || fail "Required tool missing: $tool"
done
((FAILURES == 0)) || exit 1

# These minimums match the MVP installer and certificate generation.
if ! yq --version 2>/dev/null | python3 -c '
import re, sys
s = sys.stdin.read()
m = re.search(r"version v?(\d+)\.(\d+)\.(\d+)", s)
sys.exit(0 if "mikefarah/yq" in s and m and tuple(map(int, m.groups())) >= (4, 18, 0) else 1)
'; then
  fail "Mike Farah yq >= 4.18.0 is required"
fi
if ! helm version --template '{{.Version}}' 2>/dev/null | python3 -c '
import re, sys
m = re.match(r"v(\d+)\.(\d+)\.(\d+)", sys.stdin.read())
sys.exit(0 if m and tuple(map(int, m.groups())) >= (3, 12, 0) else 1)
'; then
  fail "Helm >= 3.12.0 is required"
fi
python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))' \
  || fail "Python >= 3.12 is required"
if ! openssl version 2>/dev/null | python3 -c '
import re, sys
m = re.match(r"OpenSSL (\d+)\.", sys.stdin.read())
sys.exit(0 if m and int(m.group(1)) >= 3 else 1)
'; then
  fail "OpenSSL >= 3 is required"
fi
((FAILURES == 0)) || exit 1

MODEL="$(yq -er '.model' "${SCRIPT_DIR}/files/versions.yaml" 2>/dev/null)" || {
  fail "Praxis model selection is missing from files/versions.yaml"
  exit 1
}

if [[ -z "$CONTEXT" ]]; then
  CONTEXT="$(oc config current-context 2>/dev/null)" || {
    fail "No current kubeconfig context; pass --context CONTEXT"
    exit 1
  }
fi
k get clusterversion version -o name >/dev/null || {
  fail "Cannot read OpenShift cluster version; check context, login, and permissions"
  exit 1
}
k whoami >/dev/null || { fail "An authenticated OpenShift login is required"; exit 1; }
echo "Context: $CONTEXT"
echo "OpenAI model: $MODEL"

permission() {
  local namespace="$1" verb="$2" resource="$3"
  k auth can-i "$verb" "$resource" -n "$namespace" --quiet \
    || fail "Missing permission: $verb $resource (namespace $namespace)"
}

# A wildcard grant avoids redundant API calls for administrators. Otherwise,
# check the resource-specific grants needed by the remaining scripts.
for namespace in "$NAMESPACE" grid-system kuadrant-system redhat-ai-gateway-infra models-as-a-service openshift-ingress; do
  if k auth can-i '*' '*' -n "$namespace" --quiet; then
    continue
  fi
  case "$namespace" in
    "$NAMESPACE") resources="networkpolicies.networking.k8s.io" ;;
    grid-system) resources="secrets configmaps services serviceaccounts deployments.apps roles.rbac.authorization.k8s.io rolebindings.rbac.authorization.k8s.io networkpolicies.networking.k8s.io" ;;
    kuadrant-system) resources="secrets configmaps deployments.apps operatorgroups.operators.coreos.com subscriptions.operators.coreos.com installplans.operators.coreos.com kuadrants.kuadrant.io authorinos.operator.authorino.kuadrant.io" ;;
    redhat-ai-gateway-infra) resources="secrets" ;;
    models-as-a-service) resources="secrets externalproviders.inference.opendatahub.io externalmodels.inference.opendatahub.io maasmodelrefs.maas.opendatahub.io maassubscriptions.maas.opendatahub.io maasauthpolicies.maas.opendatahub.io" ;;
    openshift-ingress) resources="gateways.gateway.networking.k8s.io routes.route.openshift.io" ;;
  esac
  for resource in $resources; do
    for verb in get create update patch; do permission "$namespace" "$verb" "$resource"; done
  done
  for resource in deployments.apps pods services endpointslices.discovery.k8s.io configmaps secrets; do
    permission "$namespace" get "$resource"
    permission "$namespace" list "$resource"
    permission "$namespace" watch "$resource"
  done
done
if ! k auth can-i '*' '*' --all-namespaces --quiet; then
  for resource in namespaces customresourcedefinitions.apiextensions.k8s.io clusterroles.rbac.authorization.k8s.io clusterrolebindings.rbac.authorization.k8s.io adminnetworkpolicies.policy.networking.k8s.io; do
    for verb in get create update patch; do permission "$NAMESPACE" "$verb" "$resource"; done
  done
  permission "$NAMESPACE" patch datascienceclusters.datasciencecluster.opendatahub.io
  permission "$NAMESPACE" get ogxservers.ogx.io
  permission "$NAMESPACE" patch ogxservers.ogx.io
  permission "$NAMESPACE" list adminnetworkpolicies.policy.networking.k8s.io
  permission "$NAMESPACE" delete routes.route.openshift.io
  permission grid-system list networkpolicies.networking.k8s.io
  permission "$NAMESPACE" create pods/exec
  permission kuadrant-system get clusterserviceversions.operators.coreos.com
  permission kuadrant-system watch clusterserviceversions.operators.coreos.com
  permission grid-system create serviceaccounts/token
  for resource in httproutes.gateway.networking.k8s.io authpolicies.kuadrant.io gridnetworks.grid.praxis-proxy.io gridsites.grid.praxis-proxy.io inferenceproviders.grid.praxis-proxy.io; do
    for verb in get create update patch; do permission grid-system "$verb" "$resource"; done
  done
  for resource in secrets externalmodels.inference.opendatahub.io maasmodelrefs.maas.opendatahub.io maassubscriptions.maas.opendatahub.io maasauthpolicies.maas.opendatahub.io; do
    permission models-as-a-service delete "$resource"
  done
fi

if ! k get crd adminnetworkpolicies.policy.networking.k8s.io -o json \
  | jq -e 'any(.status.conditions[]?; .type == "Established" and .status == "True")' >/dev/null; then
  fail "AdminNetworkPolicy support is required for the OGX ingress trust boundary"
else
  priority="$(yq '.spec.priority' "${SCRIPT_DIR}/files/ogx-adminnetworkpolicy.yaml")"
  if ! k get adminnetworkpolicies -o json | jq -e --argjson priority "$priority" '
    all(.items[];
      if .metadata.name == "praxis-mvp-ogx" then
        .metadata.labels["app.kubernetes.io/managed-by"] == "showroom-praxis"
      else .spec.priority > $priority end)
  ' >/dev/null; then
    fail "AdminNetworkPolicy ownership or priority conflicts; confirm the Praxis policy before installation"
  fi
fi
if ! k get crd ogxservers.ogx.io -o json | jq -e '
  any(.spec.versions[]?; .served and
    .schema.openAPIV3Schema.properties.spec.properties.praxisMode.properties.praxisSelector != null)
' >/dev/null; then
  fail "The OGX operator must support native praxisMode and praxisSelector"
fi

deployment_ready() {
  local namespace="$1" name="$2"
  k -n "$namespace" get deployment "$name" -o json | jq -e '
    (.spec.replicas // 1) > 0 and
    (.status.observedGeneration // 0) >= .metadata.generation and
    (.status.updatedReplicas // 0) == (.spec.replicas // 1) and
    (.status.availableReplicas // 0) == (.spec.replicas // 1) and
    (.status.replicas // 0) == (.spec.replicas // 1)
  ' >/dev/null
}

service_ready() {
  local name="$1"
  k -n "$NAMESPACE" get service "$name" -o name >/dev/null &&
    k -n "$NAMESPACE" get endpointslices.discovery.k8s.io \
      -l "kubernetes.io/service-name=$name" -o json | jq -e '
        any(.items[]?.endpoints[]?; .conditions.ready != false and (.addresses | length) > 0)
      ' >/dev/null
}

if ! k -n "$NAMESPACE" get ogxserver "$OGX_NAME" -o json \
  | jq -e '.status.phase == "Ready"' >/dev/null; then
  fail "OGXServer $OGX_NAME is not Ready; finish ./provision.sh first"
fi
for name in "$OGX_NAME" postgres milvus etcd minio; do
  deployment_ready "$NAMESPACE" "$name" || fail "Deployment $NAMESPACE/$name is not ready"
done
for name in "${OGX_NAME}-service" postgres milvus etcd minio; do
  service_ready "$name" || fail "Service $NAMESPACE/$name has no ready endpoints"
done
if ! k -n "$NAMESPACE" get pvc postgres-pvc milvus-pvc etcd-pvc minio-pvc -o json \
  | jq -e '.items | length == 4 and all(.[]; .status.phase == "Bound")' >/dev/null; then
  fail "Showroom PostgreSQL, Milvus, etcd, and MinIO PVCs must be Bound"
fi

DEPLOYMENT="$(k -n "$NAMESPACE" get deployment "$OGX_NAME" -o json)" || {
  fail "Cannot discover the OGX deployment"
  exit 1
}
ENVIRONMENT="$(jq '[.spec.template.spec.containers[] | select(.name == "ogx") | .env[]?]' <<< "$DEPLOYMENT")"

# Resolve only requested settings. Secret data never reaches command output.
env_value() {
  local entry ref name key
  entry="$(jq -c --arg name "$1" '.[] | select(.name == $name)' <<< "$ENVIRONMENT")"
  [[ -n "$entry" ]] || return 0
  if jq -e 'has("value")' <<< "$entry" >/dev/null; then
    jq -r '.value' <<< "$entry"
    return
  fi
  for ref in secretKeyRef configMapKeyRef; do
    name="$(jq -r --arg ref "$ref" '.valueFrom[$ref].name // empty' <<< "$entry")"
    key="$(jq -r --arg ref "$ref" '.valueFrom[$ref].key // empty' <<< "$entry")"
    [[ -n "$name" ]] || continue
    if [[ "$ref" == secretKeyRef ]]; then
      k -n "$NAMESPACE" get secret "$name" -o json \
        | jq -er --arg key "$key" '.data[$key] | select(. != null) | @base64d'
    else
      k -n "$NAMESPACE" get configmap "$name" -o json \
        | jq -er --arg key "$key" '.data[$key] | select(. != null)'
    fi
    return
  done
  return 1
}

for setting in OPENAI_API_KEY POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD EMBEDDING_MODEL EMBEDDING_PROVIDER EMBEDDING_DIMENSION VLLM_EMBEDDING_URL VLLM_EMBEDDING_API_TOKEN MILVUS_ENDPOINT S3_BUCKET_NAME S3_ENDPOINT_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  if value="$(env_value "$setting")" && [[ -n "$value" ]]; then
    echo "OK: OGX $setting is configured"
  else
    fail "OGX $setting is missing or unreadable; configure it in Showroom and reprovision"
  fi
  unset value
done
if [[ "$(env_value POSTGRES_HOST)" != postgres || "$(env_value POSTGRES_PORT)" != 5432 ]]; then
  fail "PostgreSQL differs from Showroom's postgres:5432; confirm the database target before preparation"
else
  echo "PostgreSQL: postgres.$NAMESPACE.svc:5432 (existing Showroom server)"
fi
if [[ "$(env_value ENABLE_S3)" != true ]]; then
  fail "Persistent S3 file storage is not enabled; confirm storage configuration before installation"
fi
for setting in EMBEDDING_MODEL EMBEDDING_PROVIDER EMBEDDING_DIMENSION S3_BUCKET_NAME; do
  value="$(env_value "$setting")" || continue
  if [[ "$value" =~ ^[a-zA-Z0-9_./:-]+$ ]]; then
    echo "$setting: $value"
  else
    fail "OGX $setting is ambiguous; confirm the configured value before installation"
  fi
done
unset value

unset DEPLOYMENT ENVIRONMENT

for crd in gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io authpolicies.kuadrant.io externalmodels.inference.opendatahub.io maassubscriptions.maas.opendatahub.io; do
  if ! k get crd "$crd" -o json | jq -e 'any(.status.conditions[]?; .type == "Established" and .status == "True")' >/dev/null; then
    pending "Install or enable prerequisite CRD: $crd"
  fi
done
for entry in kuadrant-system/authorino redhat-ai-gateway-infra/maas-api; do
  deployment_ready "${entry%/*}" "${entry#*/}" || pending "Install or repair $entry"
done
if ! k get gatewayclass data-science-gateway-class -o json \
  | jq -e 'any(.status.conditions[]?; .type == "Accepted" and .status == "True")' >/dev/null; then
  pending "Enable the RHOAI data-science-gateway-class"
fi
if ! k get datasciencecluster default-dsc -o json \
  | jq -e '.status.phase == "Ready"' >/dev/null; then
  fail "DataScienceCluster default-dsc is not Ready"
fi

echo "Pre-flight: $FAILURES blocker(s), $PENDING preparation prerequisite(s)."
echo "No deployment changes made. OpenAI access and authenticated API behavior will be verified after installation."
((FAILURES == 0))
