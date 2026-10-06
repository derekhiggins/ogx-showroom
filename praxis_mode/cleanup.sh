#!/usr/bin/env bash
set +x
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

USAGE="Remove Praxis, Grid, RHCL/Kuadrant and MaaS, including both Praxis databases.
Deletes grid-system, kuadrant-system, models-as-a-service and redhat-ai-gateway-infra.
Keeps OGX isolated with its configuration and praxis-mvp-ogx AdminNetworkPolicy."

parse_args "$@"
require_tools oc helm jq yq
resolve_context

setup_workdir Cleanup

# Discover APIs explicitly so missing CRDs are harmless, but failed reads are not.
k get crd -o json > "${WORK_DIR}/crds.json"
has_crd() { jq -e --arg name "$1" 'any(.items[]; .metadata.name == $name)' "${WORK_DIR}/crds.json" >/dev/null; }
delete_custom() {
  local namespace="$1" resource="$2" name="$3"
  has_crd "$resource" || return 0
  delete -n "$namespace" "$resource" "$name"
}
uninstall() {
  local release="$1" releases
  releases="$(helm list --kube-context "$CONTEXT" -n grid-system --all -o json 2>/dev/null)"
  if jq -e --arg name "$release" 'any(.[]; .name == $name)' <<< "$releases" >/dev/null; then
    helm uninstall "$release" --kube-context "$CONTEXT" -n grid-system \
      --wait --timeout="$TIMEOUT" >/dev/null 2>&1
  fi
}
database_sql() {
  # Use only the pod's credentials; psql errors may contain connection details.
  # shellcheck disable=SC2016
  k -n "$NAMESPACE" exec -i deployment/postgres -- bash -c \
    'exec psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v owner="$POSTGRESQL_USER"' >/dev/null
}
postgres="$(k -n "$NAMESPACE" get deployment postgres --ignore-not-found -o name)"
if [[ -n "$postgres" ]]; then
  database_sql <<'SQL' || die "Cannot validate Praxis database ownership on Showroom PostgreSQL"
SELECT 1 / (pg_get_userbyid(datdba) = :'owner')::int
FROM pg_database WHERE datname IN ('praxis_mvp', 'praxis_mvp_maas');
SQL
fi

echo "Cleaning up Praxis on context: $CONTEXT"
echo "Removes the shared Grid/RHCL/MaaS stack and all data in praxis_mvp and praxis_mvp_maas."

# Establish isolation even when cleanup follows only a partial preparation.
if has_crd ogxservers.ogx.io; then
  cr="$(k -n "$NAMESPACE" get ogxserver ogx-distribution --ignore-not-found -o json)"
  if [[ -n "$cr" ]]; then
    has_crd adminnetworkpolicies.policy.networking.k8s.io || die "AdminNetworkPolicy is required to leave OGX isolated"
    port="$(jq -r '.spec.network.port // 8321' <<< "$cr")"
    [[ "$port" =~ ^[0-9]+$ ]] && ((port > 0 && port <= 65535)) || die "Invalid OGX API port"
    PORT="$port" yq -o=json \
      '(.spec.ingress[0].ports[0].portNumber.port, .spec.ingress[1].ports[0].portNumber.port) = env(PORT)' \
      "${FILES}/ogx-adminnetworkpolicy.yaml" > "${WORK_DIR}/isolation.json"
    policies="$(k get adminnetworkpolicies -o json)"
    if ! jq -e --slurpfile expected "${WORK_DIR}/isolation.json" '
      all(.items[];
        if .metadata.name == "praxis-mvp-ogx" then
          .metadata.labels["app.kubernetes.io/managed-by"] == "showroom-praxis" and .spec == $expected[0].spec
        else .spec.priority != 0 end)
    ' <<< "$policies" >/dev/null; then
      die "OGX isolation policy ownership, configuration or priority conflicts"
    fi
    k apply -f "${WORK_DIR}/isolation.json" >/dev/null
    poll_until 120 adminnetworkpolicy_ready praxis-mvp-ogx || die "OGX isolation is not ready"
    route="$(k -n "$NAMESPACE" get route ogx-distribution --ignore-not-found -o json)"
    if [[ -n "$route" ]] && ! jq -e '
      .metadata.annotations["meta.helm.sh/release-name"] == "ogx-rhoai" and
      .spec.to.name == "ogx-distribution-service"
    ' <<< "$route" >/dev/null; then
      die "OGX Route is not the Showroom Route; confirm external exposure"
    fi
    k -n "$NAMESPACE" patch ogxserver ogx-distribution --type=merge \
      -p '{"spec":{"network":{"externalAccess":{"enabled":false}}}}' >/dev/null
    delete -n "$NAMESPACE" route ogx-distribution
  fi
fi

echo "Removing public routing and Praxis gateways..."
delete -n openshift-ingress route praxis-mvp
delete_custom grid-system httproutes.gateway.networking.k8s.io praxis-mvp
delete_custom grid-system authpolicies.kuadrant.io praxis-mvp
delete_custom openshift-ingress gateways.gateway.networking.k8s.io praxis-mvp
uninstall consumer-gateway
uninstall provider-gateway
uninstall grid-site

echo "Draining MaaS tenants before removing controllers..."
controller="$(k -n "$NAMESPACE" get deployment maas-controller --ignore-not-found -o name)"
if [[ -n "$controller" ]]; then
  # Disable bootstrap/self-heal and let tenant finalizers finish with controllers alive.
  k -n "$NAMESPACE" annotate "$controller" maas.opendatahub.io/teardown-requested=true --overwrite >/dev/null
  k -n "$NAMESPACE" wait "$controller" \
    --for=jsonpath='{.metadata.annotations.maas\.opendatahub\.io/teardown-completed}'=true \
    --request-timeout=0 --timeout="$TIMEOUT" >/dev/null
fi

# Keep controllers running until their custom-resource finalizers finish.
jq -r '.items[] | select(.spec.group == "grid.praxis-proxy.io" or
  .spec.group == "maas.opendatahub.io" or .spec.group == "inference.opendatahub.io") |
  [.metadata.name, .spec.scope] | @tsv' "${WORK_DIR}/crds.json" > "${WORK_DIR}/mode-crds"
while IFS=$'\t' read -r resource scope; do
  if [[ "$scope" == Namespaced ]]; then
    delete "$resource" --all --all-namespaces
  else
    delete "$resource" --all
  fi
done < "${WORK_DIR}/mode-crds"
delete_custom openshift-ingress authpolicies.kuadrant.io maas-gateway-auth
delete_custom openshift-ingress gateways.gateway.networking.k8s.io maas-default-gateway

dsc_removed() {
  k get datasciencecluster default-dsc -o json | jq -e --argjson generation "$1" '
    (.status.observedGeneration // 0) >= $generation and
    .status.components.aigateway.managementState == "Removed" and
    .status.components.modelsAsAService.managementState == "Removed"
  ' >/dev/null
}
echo "Disabling RHOAI MaaS and AI gateway..."
if has_crd datascienceclusters.datasciencecluster.opendatahub.io; then
  dsc="$(k get datasciencecluster default-dsc --ignore-not-found -o name)"
  if [[ -n "$dsc" ]]; then
    generation="$(k patch datasciencecluster default-dsc --type=merge -o json \
      -p '{"spec":{"components":{"aigateway":{"managementState":"Removed","modelsAsAService":{"managementState":"Removed"}}}}}' \
      | jq -r '.metadata.generation')"
    poll_until 900 dsc_removed "$generation" || die "RHOAI did not reconcile MaaS/AI gateway removal"
  fi
fi

echo "Removing RHCL/Kuadrant custom resources and operators..."
jq -r '[.items[] | select(.spec.group == "kuadrant.io" or (.spec.group | endswith(".kuadrant.io")))] |
  sort_by(if .metadata.name == "kuadrants.kuadrant.io" then 1
    elif .metadata.name == "authorinos.operator.authorino.kuadrant.io" or
      .metadata.name == "limitadors.limitador.kuadrant.io" then 2 else 0 end) |
  .[] | [.metadata.name, .spec.scope] | @tsv' "${WORK_DIR}/crds.json" > "${WORK_DIR}/rhcl-crds"
while IFS=$'\t' read -r resource scope; do
  if [[ "$scope" == Namespaced ]]; then
    delete "$resource" --all --all-namespaces
  else
    delete "$resource" --all
  fi
done < "${WORK_DIR}/rhcl-crds"
uninstall grid-operator
delete namespace grid-system models-as-a-service redhat-ai-gateway-infra kuadrant-system

# OLM cluster-scoped resources can outlive the operator namespace.
for kind in clusterrole clusterrolebinding validatingwebhookconfiguration mutatingwebhookconfiguration apiservice; do
  delete "$kind" -l olm.owner.namespace=kuadrant-system
done
while IFS=$'\t' read -r resource _; do
  delete crd "$resource"
done < "${WORK_DIR}/mode-crds"
while IFS=$'\t' read -r resource _; do
  delete crd "$resource"
done < "${WORK_DIR}/rhcl-crds"
delete -n "$NAMESPACE" networkpolicy praxis-mvp-postgres praxis-mvp-maas-postgres

echo "Removing Praxis databases..."
if [[ -n "$postgres" ]]; then
  database_sql <<'SQL' || die "Cannot remove Praxis databases; check PostgreSQL and database ownership"
SELECT 1 / (pg_get_userbyid(datdba) = :'owner')::int
FROM pg_database WHERE datname IN ('praxis_mvp', 'praxis_mvp_maas');
SELECT format('DROP DATABASE %I WITH (FORCE)', datname)
FROM pg_database WHERE datname IN ('praxis_mvp', 'praxis_mvp_maas');
\gexec
SQL
else
  echo "Showroom PostgreSQL deployment is absent; database deletion was skipped."
fi
echo "Praxis cleanup complete. OGX configuration and ingress isolation are retained."
