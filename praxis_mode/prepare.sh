#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="${SCRIPT_DIR}/files"
CONTEXT=""
NAMESPACE=redhat-ods-applications
TIMEOUT=15m

die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  echo "Usage: $0 [--context CONTEXT]"
  echo "Prepare Praxis storage, Grid, certificates and MaaS/Authorino prerequisites."
}
k() { oc --context "$CONTEXT" --request-timeout=30s "$@" 2>/dev/null; }
apply() { k apply -f - >/dev/null; }
wait_for() { k wait --request-timeout=0 --timeout="$TIMEOUT" "$@" >/dev/null; }
rollout() { k -n "$1" rollout status "deployment/$2" --request-timeout=0 --timeout="$TIMEOUT" >/dev/null; }

while (($#)); do
  case "$1" in
    --context)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "--context requires a value"
      CONTEXT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
command -v oc >/dev/null || die "oc is required"
if [[ -z "$CONTEXT" ]]; then
  CONTEXT="$(oc config current-context 2>/dev/null)" || die "Pass --context CONTEXT"
fi
"${SCRIPT_DIR}/pre-flight.sh" --context "$CONTEXT"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'echo "ERROR: Preparation failed at line $LINENO. Resolve the prerequisite and rerun." >&2' ERR
MODEL="$(yq '.model' "${FILES}/versions.yaml")"
VERSION="$(yq '.grid.version' "${FILES}/versions.yaml")"
RELEASE_URL="$(yq '.grid.releaseUrl' "${FILES}/versions.yaml")"
USER_NAME="$(k whoami)"

echo "Preparing Praxis on context: $CONTEXT"
echo "Creates/reuses praxis_mvp, Grid operator/registration, gateway TLS Secrets, and MaaS prerequisites."
echo "May enable shared RHOAI MaaS components and roll Grid, Kuadrant or Authorino."

for chart in operator site; do
  archive="${WORK_DIR}/grid-${chart}-${VERSION}.tgz"
  curl -fsSL --connect-timeout 15 --max-time 120 \
    "${RELEASE_URL}/grid-${chart}-${VERSION}.tgz" -o "$archive" 2>/dev/null
  expected="$(yq ".grid.${chart}Sha256" "${FILES}/versions.yaml")"
  python3 - "$archive" "$expected" <<'PY'
import hashlib, pathlib, sys
sys.exit(0 if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() == sys.argv[2] else 1)
PY
done

ENVIRONMENT="$(k -n "$NAMESPACE" get deployment ogx-distribution -o json \
  | jq '[.spec.template.spec.containers[] | select(.name == "ogx") | .env[]?]')"
env_value() {
  local entry ref name key
  entry="$(jq -c --arg name "$1" '.[] | select(.name == $name)' <<< "$ENVIRONMENT")"
  [[ -n "$entry" ]] || return 1
  if jq -e 'has("value")' <<< "$entry" >/dev/null; then
    jq -ej '.value' <<< "$entry"
    return
  fi
  for ref in secretKeyRef configMapKeyRef; do
    name="$(jq -r --arg ref "$ref" '.valueFrom[$ref].name // empty' <<< "$entry")"
    key="$(jq -r --arg ref "$ref" '.valueFrom[$ref].key // empty' <<< "$entry")"
    [[ -n "$name" ]] || continue
    if [[ "$ref" == secretKeyRef ]]; then
      k -n "$NAMESPACE" get secret "$name" -o json | jq -ej --arg key "$key" '.data[$key] | select(. != null) | @base64d'
    else
      k -n "$NAMESPACE" get configmap "$name" -o json | jq -ej --arg key "$key" '.data[$key] | select(. != null)'
    fi
    return
  done
  return 1
}
env_value OPENAI_API_KEY > "${WORK_DIR}/openai-key"
env_value POSTGRES_USER > "${WORK_DIR}/pg-user"
env_value POSTGRES_PASSWORD > "${WORK_DIR}/pg-password"
[[ -s "${WORK_DIR}/openai-key" && -s "${WORK_DIR}/pg-user" && -s "${WORK_DIR}/pg-password" ]] \
  || die "OGX OpenAI or PostgreSQL credentials are empty"
if ! k -n "$NAMESPACE" get secret postgres-secret -o json \
  | jq -e --rawfile user "${WORK_DIR}/pg-user" --rawfile password "${WORK_DIR}/pg-password" \
    '(.data.POSTGRES_USER | @base64d) == $user and (.data.POSTGRES_PASSWORD | @base64d) == $password' >/dev/null; then
  die "OGX credentials differ from Showroom PostgreSQL; confirm the database owner before preparation"
fi
unset ENVIRONMENT

if ! k get crd datascienceclusters.datasciencecluster.opendatahub.io -o json | jq -e '
  any(.spec.versions[]; .served and
    .schema.openAPIV3Schema.properties.spec.properties.components.properties.aigateway.properties.modelsAsAService != null)
' >/dev/null; then
  die "RHOAI does not expose aigateway.modelsAsAService; confirm a compatible RHOAI installation"
fi

for namespace in grid-system kuadrant-system redhat-ai-gateway-infra; do
  k create namespace "$namespace" --dry-run=client -o yaml | apply
done

secret_template() {
  SECRET_NAME="$1" yq -o=json 'select(.metadata.name == strenv(SECRET_NAME))' "${FILES}/secrets.yaml"
}
apply_secret() {
  # Dedicated Secrets are managed server-side to avoid credential-bearing
  # last-applied annotations and to update MVP-owned fields on migration.
  k apply --server-side --force-conflicts --field-manager=showroom-praxis -f - >/dev/null
}
secret_data() {
  k -n "$1" get secret "$2" --ignore-not-found -o json
}
decode_file() { jq -ej --arg key "$2" '.data[$key] | select(. != null) | @base64d' <<< "$1" > "$3"; }

# Keep existing gateway identities. Missing certificates under an existing CA
# require its private key; never silently replace the trust root.
ca="$(secret_data grid-system grid-ca)"
private_ca="$(secret_data grid-system praxis-ca)"
if [[ -n "$private_ca" ]]; then
  decode_file "$private_ca" ca.crt "${WORK_DIR}/ca.crt"
  decode_file "$private_ca" ca.key "${WORK_DIR}/ca.key"
  if [[ -n "$ca" ]]; then
    decode_file "$ca" ca.crt "${WORK_DIR}/public-ca.crt"
    cmp -s "${WORK_DIR}/ca.crt" "${WORK_DIR}/public-ca.crt" || die "Grid CA Secrets disagree; confirm the trust root"
  fi
elif [[ -n "$ca" ]]; then
  decode_file "$ca" ca.crt "${WORK_DIR}/ca.crt"
else
  for role in consumer provider; do
    [[ -z "$(secret_data grid-system "${role}-tls")" ]] || die "Gateway TLS exists without grid-ca; restore the existing CA"
  done
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "${WORK_DIR}/ca.key" -out "${WORK_DIR}/ca.crt" -days 365 \
    -subj /O=ai-grid/CN=praxis-mvp-ca -addext basicConstraints=critical,CA:TRUE \
    -addext keyUsage=critical,keyCertSign,cRLSign >/dev/null 2>&1
  secret_template praxis-ca | jq --rawfile crt "${WORK_DIR}/ca.crt" --rawfile key "${WORK_DIR}/ca.key" \
    '.data = {"ca.crt": ($crt | @base64), "ca.key": ($key | @base64)}' | apply_secret
fi
openssl x509 -in "${WORK_DIR}/ca.crt" -noout -checkend 0 >/dev/null 2>&1 || die "Grid CA is expired or invalid; arrange renewal"
if [[ -f "${WORK_DIR}/ca.key" ]]; then
  openssl x509 -in "${WORK_DIR}/ca.crt" -pubkey -noout > "${WORK_DIR}/cert.pub"
  openssl pkey -in "${WORK_DIR}/ca.key" -pubout > "${WORK_DIR}/key.pub" 2>/dev/null
  cmp -s "${WORK_DIR}/cert.pub" "${WORK_DIR}/key.pub" || die "Grid CA certificate and private key do not match"
fi
if [[ -z "$ca" ]]; then
  secret_template grid-ca | jq --rawfile crt "${WORK_DIR}/ca.crt" '.data = {"ca.crt": ($crt | @base64)}' | apply_secret
fi
for role in consumer provider; do
  new_tls=false
  tls="$(secret_data grid-system "${role}-tls")"
  if [[ -n "$tls" ]]; then
    decode_file "$tls" tls.crt "${WORK_DIR}/${role}.crt"
    decode_file "$tls" tls.key "${WORK_DIR}/${role}.key"
    decode_file "$tls" ca.crt "${WORK_DIR}/${role}-ca.crt"
    cmp -s "${WORK_DIR}/ca.crt" "${WORK_DIR}/${role}-ca.crt" || die "$role TLS uses a different CA"
  else
    [[ -f "${WORK_DIR}/ca.key" ]] || die "Missing $role TLS and CA private key; supply grid-system/praxis-ca with ca.crt and ca.key"
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "${WORK_DIR}/${role}.key" -out "${WORK_DIR}/${role}.csr" \
      -subj "/O=ai-grid/CN=mvp-${role}" \
      -addext "subjectAltName=DNS:mvp-${role}.grid.internal,DNS:${role}-gateway.grid-system.svc.cluster.local" \
      -addext keyUsage=digitalSignature,keyEncipherment -addext extendedKeyUsage=clientAuth,serverAuth >/dev/null 2>&1
    openssl x509 -req -in "${WORK_DIR}/${role}.csr" -CA "${WORK_DIR}/ca.crt" -CAkey "${WORK_DIR}/ca.key" \
      -CAcreateserial -out "${WORK_DIR}/${role}.crt" -days 365 -copy_extensions copyall >/dev/null 2>&1
    new_tls=true
  fi
  openssl verify -CAfile "${WORK_DIR}/ca.crt" "${WORK_DIR}/${role}.crt" >/dev/null 2>&1 \
    || die "$role certificate is invalid or expired; arrange renewal"
  openssl x509 -in "${WORK_DIR}/${role}.crt" -pubkey -noout > "${WORK_DIR}/cert.pub"
  openssl pkey -in "${WORK_DIR}/${role}.key" -pubout > "${WORK_DIR}/key.pub" 2>/dev/null
  cmp -s "${WORK_DIR}/cert.pub" "${WORK_DIR}/key.pub" || die "$role certificate and key do not match"
  for purpose in sslclient sslserver; do
    openssl verify -purpose "$purpose" -CAfile "${WORK_DIR}/ca.crt" "${WORK_DIR}/${role}.crt" >/dev/null 2>&1 \
      || die "$role certificate does not allow mutual TLS"
  done
  openssl x509 -in "${WORK_DIR}/${role}.crt" -noout -checkhost "${role}-gateway.grid-system.svc.cluster.local" >/dev/null 2>&1 \
    || die "$role certificate has no matching gateway hostname"
  subject="$(openssl x509 -in "${WORK_DIR}/${role}.crt" -noout -subject -nameopt RFC2253)"
  [[ "$subject" =~ (^|,)O=ai-grid(,|$) ]] || die "$role certificate lacks the ai-grid peer identity"
  if $new_tls; then
    secret_template "${role}-tls" | jq --rawfile crt "${WORK_DIR}/${role}.crt" \
      --rawfile key "${WORK_DIR}/${role}.key" --rawfile ca "${WORK_DIR}/ca.crt" \
      '.data = {"tls.crt": ($crt | @base64), "tls.key": ($key | @base64), "ca.crt": ($ca | @base64)}' | apply_secret
  fi
done
unset ca private_ca tls
echo "Gateway TLS identities are ready."

database() {
  # Use the PostgreSQL pod's existing credentials, never command-line passwords.
  # shellcheck disable=SC2016
  k -n "$NAMESPACE" exec -i deployment/postgres -- bash -c \
    'exec psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v owner="$POSTGRESQL_USER" -v db="$1"' bash "$1" <<'SQL' >/dev/null
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'owner')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db')
\gexec
-- Reject an unexpected owner without changing database ownership.
SELECT 1 / (pg_get_userbyid(datdba) = :'owner')::int FROM pg_database WHERE datname = :'db';
SQL
}
database praxis_mvp || die "Cannot prepare praxis_mvp; check PostgreSQL permissions and existing database ownership"
secret_template praxis-store | jq --rawfile user "${WORK_DIR}/pg-user" --rawfile password "${WORK_DIR}/pg-password" \
  '.data = {POSTGRES_USER: ($user | @base64), POSTGRES_PASSWORD: ($password | @base64)}' | apply_secret
secret_template openai-credential | jq --rawfile token "${WORK_DIR}/openai-key" '.data = {token: ($token | @base64)}' | apply_secret

maas_db="$(secret_data redhat-ai-gateway-infra maas-db-config)"
if [[ -z "$maas_db" ]]; then
  database praxis_mvp_maas || die "Cannot prepare the MaaS database; check PostgreSQL ownership"
  python3 - "$WORK_DIR" <<'PY'
import pathlib, sys
from urllib.parse import quote
directory = pathlib.Path(sys.argv[1])
user, password = (quote((directory / name).read_text(), safe="") for name in ("pg-user", "pg-password"))
(directory / "maas-url").write_text(f"postgresql://{user}:{password}@postgres.redhat-ods-applications.svc.cluster.local:5432/praxis_mvp_maas?sslmode=disable")
PY
  secret_template maas-db-config | jq --rawfile url "${WORK_DIR}/maas-url" '.data = {DB_CONNECTION_URL: ($url | @base64)}' | apply_secret
elif ! jq -e '.data.DB_CONNECTION_URL | type == "string" and length > 0' <<< "$maas_db" >/dev/null; then
  die "Existing maas-db-config has no DB_CONNECTION_URL; confirm MaaS database configuration"
fi
unset maas_db
apply < "${FILES}/database-networkpolicies.yaml"
echo "Praxis database and credential Secrets are ready. Existing MaaS database configuration is retained."

helm upgrade --install grid-operator "${WORK_DIR}/grid-operator-${VERSION}.tgz" --kube-context "$CONTEXT" \
  -n grid-system --reuse-values -f "${FILES}/grid-operator.yaml" --wait --timeout "$TIMEOUT" >/dev/null 2>&1
for crd in gridnetworks gridsites inferenceproviders agenttoolproviders; do
  wait_for --for=condition=Established "crd/${crd}.grid.praxis-proxy.io"
done
provider="$(k -n grid-system get inferenceprovider openai-mvp-provider --ignore-not-found -o json)"
if [[ -n "$provider" ]] && ! jq -e '.spec.endpoint == "https://api.openai.com" and .spec.gridNetworkRef == "praxis-mvp"' <<< "$provider" >/dev/null; then
  die "Existing Grid provider differs from the MVP; confirm registration before updating"
fi
[[ -n "$provider" ]] || provider='{}'
printf '%s' "$provider" > "${WORK_DIR}/provider.json"
yq -o=json '.' "${FILES}/grid-site.yaml" | jq --arg model "$MODEL" --slurpfile existing "${WORK_DIR}/provider.json" '
  .inferenceProviders[0] = ((.inferenceProviders[0] * ($existing[0].spec // {})) |
    .models = ((.models // []) + [{name: $model, capabilities: ["text_generation"]}] | unique_by(.name)))
' > "${WORK_DIR}/grid-site.json"
helm upgrade --install grid-site "${WORK_DIR}/grid-site-${VERSION}.tgz" --kube-context "$CONTEXT" \
  -n grid-system --reuse-values -f "${WORK_DIR}/grid-site.json" --wait --timeout "$TIMEOUT" >/dev/null 2>&1
echo "Grid $VERSION operator and registration are ready."

subscription="$(k -n kuadrant-system get subscription rhcl-operator --ignore-not-found -o json)"
if [[ -z "$subscription" ]]; then
  apply < "${FILES}/rhcl.yaml"
  subscription="$(k -n kuadrant-system get subscription rhcl-operator -o json)"
fi
csv="$(yq 'select(.kind == "Subscription") | .spec.startingCSV' "${FILES}/rhcl.yaml")"
# Also resume a bootstrap interrupted before its install plan was approved.
if jq -e --arg csv "$csv" '.spec.installPlanApproval == "Manual" and .spec.startingCSV == $csv' <<< "$subscription" >/dev/null; then
  wait_for -n kuadrant-system subscription/rhcl-operator --for=jsonpath='{.status.installPlanRef.name}'
  plan="$(k -n kuadrant-system get subscription rhcl-operator -o jsonpath='{.status.installPlanRef.name}')"
  install_plan="$(k -n kuadrant-system get installplan "$plan" -o json)"
  if ! jq -e '.spec.approved == true' <<< "$install_plan" >/dev/null; then
    if ! jq -e --arg csv "$csv" '
      .spec.clusterServiceVersionNames | any(. == $csv) and all(.[]; (startswith("rhcl-operator.") | not) or . == $csv)
    ' <<< "$install_plan" >/dev/null; then
      die "RHCL install plan does not match the pinned release; confirm the available catalog version"
    fi
    k -n kuadrant-system patch installplan "$plan" --type=merge -p '{"spec":{"approved":true}}' >/dev/null
  fi
fi
wait_for -n kuadrant-system subscription/rhcl-operator --for=jsonpath='{.status.currentCSV}'
csv="$(k -n kuadrant-system get subscription rhcl-operator -o jsonpath='{.status.currentCSV}')"
wait_for -n kuadrant-system --for=create "csv/$csv"
wait_for -n kuadrant-system "csv/$csv" --for=jsonpath='{.status.phase}'=Succeeded
wait_for --for=condition=Established crd/authpolicies.kuadrant.io crd/kuadrants.kuadrant.io
for name in authorino-operator limitador-operator-controller-manager; do
  wait_for -n kuadrant-system --for=create "deployment/$name"
  rollout kuadrant-system "$name"
done
kuadrant="$(k -n kuadrant-system get kuadrant kuadrant --ignore-not-found -o json)"
if [[ -z "$kuadrant" ]]; then
  yq 'select(.kind == "Kuadrant")' "${FILES}/kuadrant.yaml" | apply
fi
yq 'select(.kind == "ConfigMap")' "${FILES}/kuadrant.yaml" | apply
if ! k -n kuadrant-system wait kuadrant/kuadrant --for=condition=Ready --timeout=60s --request-timeout=0 >/dev/null; then
  k -n kuadrant-system rollout restart deployment/kuadrant-operator-controller-manager >/dev/null
  wait_for -n kuadrant-system kuadrant/kuadrant --for=condition=Ready
fi
wait_for -n kuadrant-system configmap/openshift-service-ca.crt --for=jsonpath='{.data.service-ca\.crt}'
k -n kuadrant-system get authorino authorino -o json > "${WORK_DIR}/authorino.json"
yq -o=json '.' "${FILES}/authorino-patch.yaml" | jq --slurpfile existing "${WORK_DIR}/authorino.json" '
  .spec.volumes.items = (($existing[0].spec.volumes.items // [] | map(select(.name != "openshift-service-ca"))) + .spec.volumes.items)
' > "${WORK_DIR}/authorino-patch.json"
k -n kuadrant-system patch authorino authorino --type=merge --patch-file "${WORK_DIR}/authorino-patch.json" >/dev/null
k -n kuadrant-system set env deployment/authorino SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt >/dev/null
rollout kuadrant-system authorino

k patch datasciencecluster default-dsc --type=merge \
  -p '{"spec":{"components":{"aigateway":{"managementState":"Managed","modelsAsAService":{"managementState":"Managed"}}}}}' >/dev/null
wait_for --for=condition=Established crd/gateways.gateway.networking.k8s.io
gateway="$(k -n openshift-ingress get gateway maas-default-gateway --ignore-not-found -o json)"
if [[ -z "$gateway" ]]; then
  apply < "${FILES}/maas-gateway.yaml"
elif ! jq -e '.spec.gatewayClassName == "data-science-gateway-class" and
  any(.spec.listeners[]?; .protocol == "HTTPS" and .port == 443)' <<< "$gateway" >/dev/null; then
  die "Existing MaaS gateway differs from the MVP HTTPS gateway; confirm gateway configuration"
fi
wait_for -n redhat-ai-gateway-infra --for=create deployment/maas-api
rollout redhat-ai-gateway-infra maas-api
for crd in externalproviders.inference.opendatahub.io externalmodels.inference.opendatahub.io maasmodelrefs.maas.opendatahub.io maassubscriptions.maas.opendatahub.io maasauthpolicies.maas.opendatahub.io; do
  wait_for --for=condition=Established "crd/$crd"
done
wait_for --for=create namespace/models-as-a-service
secret_template praxis-mvp-openai | jq --rawfile token "${WORK_DIR}/openai-key" '.data = {"api-key": ($token | @base64)}' | apply_secret

# Keep existing owners, groups, model references and limits on shared MaaS
# registration resources; add only this setup user.
for entry in MaaSSubscription:maassubscription MaaSAuthPolicy:maasauthpolicy; do
  kind="${entry%:*}"
  existing="$(k -n models-as-a-service get "${entry#*:}" praxis-mvp --ignore-not-found -o json)"
  [[ -n "$existing" ]] || existing='{}'
  printf '%s' "$existing" > "${WORK_DIR}/${kind}.json"
done
yq -o=json '.' "${FILES}/maas-registration.yaml" | jq --arg model "$MODEL" --arg user "$USER_NAME" \
  --slurpfile subscription "${WORK_DIR}/MaaSSubscription.json" --slurpfile policy "${WORK_DIR}/MaaSAuthPolicy.json" '
  if .kind == "ExternalModel" then
    .spec.modelName = $model | .spec.externalProviderRefs[0].targetModel = $model
  elif .kind == "MaaSSubscription" then
    .spec = (.spec * ($subscription[0].spec // {})) |
    .spec.owner.users = ((.spec.owner.users // []) + [$user] | unique) |
    .spec.modelRefs = ((.spec.modelRefs // []) |
      if any(.name == "praxis-mvp" and .namespace == "models-as-a-service") then .
      else . + [{name: "praxis-mvp", namespace: "models-as-a-service", tokenRateLimits: [{limit: 10000, window: "1m"}]}] end)
  elif .kind == "MaaSAuthPolicy" then
    .spec = (.spec * ($policy[0].spec // {})) |
    .spec.subjects.users = ((.spec.subjects.users // []) + [$user] | unique) |
    .spec.modelRefs = ((.spec.modelRefs // []) |
      if any(.name == "praxis-mvp" and .namespace == "models-as-a-service") then .
      else . + [{name: "praxis-mvp", namespace: "models-as-a-service"}] end)
  else . end
' | apply
wait_for -n models-as-a-service maassubscription/praxis-mvp --for=jsonpath='{.status.phase}'=Active
wait_for -n openshift-ingress --for=create authpolicy/maas-gateway-auth
wait_for -n openshift-ingress authpolicy/maas-gateway-auth --for=condition=Enforced
echo "Preparation complete: database, Grid, TLS, OpenAI $MODEL registration and MaaS authentication prerequisites are ready."
echo "Next: install.sh will switch the gateways and OGX into Praxis mode."
