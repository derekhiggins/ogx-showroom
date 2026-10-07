# shellcheck shell=bash
# shellcheck disable=SC2034  # FILES/NAMESPACE/TIMEOUT are used by the sourcing scripts.
# Shared helpers for the Praxis mode scripts.
# Source after computing SCRIPT_DIR; set USAGE before calling parse_args.
# Set REQUEST_TIMEOUT before sourcing to override the default oc timeout.

FILES="${SCRIPT_DIR}/files"
CONTEXT=""
NAMESPACE=redhat-ods-applications
TIMEOUT=15m
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30s}"
USAGE=""

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  echo "Usage: $0 [--context CONTEXT]"
  printf '%s\n' "$USAGE"
}

k() { oc --context "$CONTEXT" --request-timeout="$REQUEST_TIMEOUT" "$@" 2>/dev/null; }
apply() { k apply -f - >/dev/null; }
delete() { k delete --request-timeout=0 --ignore-not-found --timeout="$TIMEOUT" "$@" >/dev/null; }
wait_for() {
  echo "Waiting (timeout $TIMEOUT): $*" >&2
  k wait --request-timeout=0 --timeout="$TIMEOUT" "$@" >/dev/null
}
rollout() {
  echo "Waiting for deployment $1/$2 (timeout $TIMEOUT)..." >&2
  k -n "$1" rollout status "deployment/$2" --request-timeout=0 --timeout="$TIMEOUT" >/dev/null
}

parse_args() {
  while (($#)); do
    case "$1" in
      --context)
        [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "--context requires a value"
        CONTEXT="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 1 ;;
    esac
  done
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || die "$tool is required"
  done
}

resolve_context() {
  if [[ -z "$CONTEXT" ]]; then
    CONTEXT="$(oc config current-context 2>/dev/null)" || die "Pass --context CONTEXT"
  fi
}

preflight() { "${SCRIPT_DIR}/pre-flight.sh" --context "$CONTEXT"; }

# Run a command every 5 seconds until it succeeds or the timeout expires.
# On success its standard output is left in POLL_OUTPUT; output from failed
# attempts is discarded.
poll_until() {
  local seconds="$1" deadline
  shift
  deadline=$((SECONDS + seconds))
  while :; do
    if POLL_OUTPUT="$("$@")"; then
      return 0
    fi
    ((SECONDS < deadline)) || return 1
    sleep 5
  done
}

# The CNI has observed and accepted the current AdminNetworkPolicy generation.
adminnetworkpolicy_ready() {
  k get adminnetworkpolicy "$1" -o json | jq -e '
    .metadata.generation as $generation |
    (.status.conditions // []) | length > 0 and
    all(.[]; .status == "True" and (.observedGeneration // $generation) >= $generation)
  ' >/dev/null
}

# Load the OGX container's environment into ENVIRONMENT for env_value.
load_ogx_environment() {
  local deployment
  deployment="$(k -n "$NAMESPACE" get deployment "${1:-ogx-distribution}" -o json)" || return 1
  ENVIRONMENT="$(jq '[.spec.template.spec.containers[] | select(.name == "ogx") | .env[]?]' <<< "$deployment")"
}

# Resolve one OGX setting, following Secret and ConfigMap references. Prints the
# value without a trailing newline so credentials can be written to files
# verbatim. Secret data never reaches command output.
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
      k -n "$NAMESPACE" get secret "$name" -o json \
        | jq -ej --arg key "$key" '.data[$key] | select(. != null) | @base64d'
    else
      k -n "$NAMESPACE" get configmap "$name" -o json \
        | jq -ej --arg key "$key" '.data[$key] | select(. != null)'
    fi
    return
  done
  return 1
}

# Temporary directory plus the standard interrupt/failure traps.
setup_workdir() {
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # shellcheck disable=SC2064  # $1 must expand now, $LINENO when the trap fires.
  trap "echo \"ERROR: $1 failed at line \$LINENO. Resolve the failure and rerun.\" >&2" ERR
}
