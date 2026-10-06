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
wait_for() { k wait --request-timeout=0 --timeout="$TIMEOUT" "$@" >/dev/null; }
rollout() { k -n "$1" rollout status "deployment/$2" --request-timeout=0 --timeout="$TIMEOUT" >/dev/null; }

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

# Temporary directory plus the standard interrupt/failure traps.
setup_workdir() {
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # shellcheck disable=SC2064  # $1 must expand now, $LINENO when the trap fires.
  trap "echo \"ERROR: $1 failed at line \$LINENO. Resolve the failure and rerun.\" >&2" ERR
}
