#!/usr/bin/env bash
# The acceptance eyeball in one call in and one out: packets for every item awaiting acceptance,
# then a verdict per item.
#
# Usage (inside the repo):
#   accept.sh packet <plan-file> [--diff-under <lines>] [--group-over <files>] [--max-chars <n>] [<ID>…]
#       One packet per item (default: every item in state `accepting`, the ones cycle.sh reports as
#       `accept` needs): item and PR; the criteria (the issue's checklist, or the `ask`); the worker's
#       criteria and `checked`; the PR's files with additions/deletions, grouped by top-level
#       directory over --group-over files (default 15); the diff itself only when the PR changes
#       fewer than --diff-under lines (default 150), cut to fit --max-chars (default 1000).
#   accept.sh verdict <plan-file> <ID> ok|gap "<text>"
#       ok: acceptance "ok", state in-review, tag moved, in-review event.
#       gap: acceptance = <text>, state feedback (reason "acceptance follow-up"), the follow-up sent
#       to the worker's terminal, acceptance-gap and follow-up-sent events. A second gap on an item
#       is refused (exit 1): note the remaining gap under the table instead.
# Exit: 0 ok; 3 not the plan's owner; 1 anything else.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
die() { echo "accept: $*" >&2; exit 1; }
usage() { sed -n '6,18p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cmd=${1:-}; shift || usage
plan=${1:-}; shift || usage
[[ -f $plan ]] || die "no plan file $plan"
P=$(jq -c . "$plan") || die "unreadable plan"
item() { jq -c --arg id "$1" '[.items[] | select(.id == $id)][0] // empty' <<<"$P"; }
cut_to() { # cut_to <n> [<marker>]: stdin cut to n characters, marked when cut
  local s; s=$(cat)
  if ((${#s} > $1)); then printf '%s%s' "${s:0:$1}" "${2:-…}"; else printf '%s' "$s"; fi
}

packet() {
  local diff_under=150 group_over=15 budget=1000 ids=() id it pr num title crit ask files lines adds dels diff out body
  while (($#)); do
    case $1 in
      --diff-under) diff_under=${2:?}; shift 2 ;;
      --group-over) group_over=${2:?}; shift 2 ;;
      --max-chars) budget=${2:?}; shift 2 ;;
      -*) usage ;;
      *) ids+=("$1"); shift ;;
    esac
  done
  ((${#ids[@]})) || while IFS= read -r id; do ids+=("$id"); done < <(jq -r '.items[] | select(.state == "accepting") | .id' <<<"$P")
  for id in ${ids[@]+"${ids[@]}"}; do
    it=$(item "$id"); [[ -n $it ]] || die "no item $id in the plan"
    pr=$(jq -r '.pr // empty' <<<"$it"); title=$(jq -r '.title // empty' <<<"$it")
    out="== $id${title:+ $title} — ${pr:-no PR}"$'\n'
    # criteria: free-text items carry their ask; tracker items, the issue's checklist
    ask=$(jq -r '.ask // .text // empty' <<<"$it")
    if [[ -n $ask ]]; then crit=$ask
    else
      body=$(gh issue view "${id#\#}" --json body 2>/dev/null </dev/null | jq -r '.body // empty' 2>/dev/null)
      crit=$(grep -E '^[[:space:]]*[-*] \[[ xX]\]' <<<"$body" | sed -E 's/^[[:space:]]+//' || true)
      [[ -n $crit ]] || crit=$(printf '%s' "$body" | cut_to 300)
      [[ -n $crit ]] || crit="(issue body unavailable)"
    fi
    out+="criteria: $(printf '%s' "$crit" | cut_to 400 | tr '\n' '|')"$'\n'
    out+=$(jq -r '"worker: " + (if .criteria then "criteria \(.criteria.met)/\(.criteria.total)"
        + (if (.criteria.unmet | length) > 0 then ", unmet: " + (.criteria.unmet | join("; ")) else "" end) else "no criteria count" end)
        + (if .checked then "\nchecked: " + .checked else "" end)' <<<"$it" | cut_to 300)$'\n'
    if [[ -n $pr ]]; then
      files=$(gh pr view "$pr" --json files 2>/dev/null </dev/null | jq -c '.files // []' 2>/dev/null) || files='[]'
      [[ -n $files ]] || files='[]'
      read -r num adds dels < <(jq -r '[length, (map(.additions) | add // 0), (map(.deletions) | add // 0)] | @tsv' <<<"$files")
      lines=$((adds + dels))
      out+="files: $num, +$adds -$dels"$'\n'
      if ((num > group_over)); then
        out+=$(jq -r '[group_by(.path | split("/")[0]) | .[] | "\(.[0].path | split("/")[0])/ \(length) files +\(map(.additions) | add) -\(map(.deletions) | add)"] | join("; ")' <<<"$files" | cut_to 300)
      else
        out+=$(jq -r '[.[] | "\(.path) +\(.additions) -\(.deletions)"] | join("; ")' <<<"$files" | cut_to 300)
      fi
      out+=$'\n'
      if ((lines < diff_under)); then
        diff=$(gh pr diff "$pr" 2>/dev/null </dev/null || true)
        room=$((budget - ${#out} - 20))
        if ((room > 0)) && [[ -n $diff ]]; then
          out+="diff:"$'\n'"$(printf '%s' "$diff" | cut_to "$room" $'\n[diff cut]')"$'\n'
        fi
      else
        out+="diff: omitted ($lines lines changed; names only)"$'\n'
      fi
    fi
    printf '%s\n' "$out"
  done
}

verdict() {
  local id=${1:-} v=${2:-} text=${3:-} it state pr msg
  [[ -n $id && ( $v == ok || $v == gap ) ]] || usage
  [[ $v == ok || -n $text ]] || die "a gap needs its text"
  it=$(item "$id"); [[ -n $it ]] || die "no item $id in the plan"
  state=$(jq -r '.state' <<<"$it")
  [[ $state == accepting ]] || die "$id is $state, not accepting"
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/accept.XXXXXX"); trap 'rm -rf "$scratch"' EXIT
  if [[ $v == ok ]]; then
    P=$(jq -c --arg id "$id" --arg at "$(now)" '
      (.items[] | select(.id == $id)) |= (.acceptance = "ok" | .state = "in-review" | .reason = null)
      | .events = ((.events // []) + [{at: $at, item: $id, action: "in-review", detail: "acceptance ok"}])' <<<"$P")
  else
    if jq -e --arg id "$id" '(.events // []) | any(.item == $id and .action == "acceptance-gap")' <<<"$P" >/dev/null; then
      die "$id already had an acceptance gap; never a second round. Note the remaining gap under the table"
    fi
    "$here/send.sh" --check "$plan" "$id" || exit 1
    pr=$(jq -r '.pr // empty' <<<"$it")
    msg=$text
    if grep -qiE 'check|CI\b' <<<"$text"; then
      msg="$text Wait for \`gh pr checks${pr:+ $pr} --watch --fail-fast\`, report the result in \`checked:\`, and print your ORCHESTRATOR_WORKER_DONE block again."
    fi
    P=$(jq -c --arg id "$id" --arg g "$text" --arg m "$msg" --arg at "$(now)" '
      (.items[] | select(.id == $id)) |= (.acceptance = $g | .state = "feedback" | .reason = "acceptance follow-up")
      | .events = ((.events // []) + [{at: $at, item: $id, action: "acceptance-gap", detail: $g},
                                      {at: $at, item: $id, action: "follow-up-sent", detail: $m}])' <<<"$P")
  fi
  printf '%s' "$P" >"$scratch/plan.json"
  "$here/plan.sh" write "$scratch/plan.json" >"$scratch/out" 2>&1
  case $? in 0) ;; 3) echo taken-over; exit 3 ;; *) die "plan write failed: $(head -n 3 "$scratch/out")" ;; esac
  if [[ $v == gap ]]; then
    "$here/send.sh" --deliver "$plan" "$id" "$msg" || exit 1
    echo "gap: follow-up sent to $id"
  else
    tag_move "$id"
    echo "ok: $id in-review"
  fi
}

tag_move() { # the item's workspace to the In Review group's tag; a failure is cycle.sh's to retry
  local ws tag cli
  ws=$(jq -r --arg id "$1" '.items[] | select(.id == $id) | .workspace // empty' <<<"$P")
  [[ -n $ws ]] || return 0
  cli=$(command -v superset || command -v paradev || command -v pdev) || return 0
  tag=$(jq -r '.groups["In Review"] // "In Review"' <<<"$P")
  "$cli" workspaces update "$ws" --local --tag "$tag" </dev/null >/dev/null 2>&1 ||
    echo "accept: could not move the tag of $1; the next cycle re-applies it" >&2
}

case $cmd in
  packet) packet "$@" ;;
  verdict) verdict "$@" ;;
  *) usage ;;
esac
