# Shared by the runwaves scripts: source it after setting $here (the scripts directory).

# The host running the workers: orca inside an Orca terminal that is not also a Paradev one, else
# paradev. On orca, a plan item's workspace is its Orca dispatch ID and its terminal Orca's handle.
backend() { if [[ -z ${SUPERSET_TERMINAL_ID:-} && -n ${ORCA_TERMINAL_HANDLE:-} ]]; then echo orca; else echo paradev; fi; }

# How a follow-up asks for the worker's final report: Orca workers report through Orca itself.
report_ask() { if [[ $(backend) == orca ]]; then echo "report back"; else echo "print your RUNWAVES_WORKER_DONE block"; fi; }

# The Orca CLI for this session (Orca exports ORCA_CLI_COMMAND for managed WSL sessions).
orca_cli() { "${ORCA_CLI_COMMAND:-orca}" "$@"; }

# The repo's default branch from origin/HEAD, offline; main when origin/HEAD is unset.
default_branch() {
  local b
  b=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
  echo "${b:-main}"
}

# plan_jq <filter> <plan-file> [jq args...]: jq with planlib.jq's defs. A dependency cycle prints one
# line naming the plan and exits 1; any other jq error passes through, also exit 1.
plan_jq() {
  local out filter=$1 plan=$2
  shift 2
  out=$(jq -L "$here" "$@" "include \"planlib\"; $filter" "$plan" 2>&1) || {
    case $out in
      *"dependency cycle"*) echo "dependency cycle in $plan" >&2 ;;
      *) printf '%s\n' "$out" >&2 ;;
    esac
    return 1
  }
  printf '%s\n' "$out"
}
