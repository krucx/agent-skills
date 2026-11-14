#!/usr/bin/env bash
# Answer every Preflight question of SKILL.md in one call and print one JSON object: tools, auth,
# host, repo, project, plan, groups, presets. Everything is reported whatever the exit code.
# Never starts the host, installs or connects anything; uses references/cli-surface.md's forms.
#
# Usage (inside the repo):
#   preflight.sh [--mode run|continue|report|close] [--harness <name>...]
#
# Exit: 0 nothing to ask; 1 a tool, auth or host failure (see "error"); 2 repo not on GitHub or no
# project; 3 live owner (run/continue/close); 4 stale owner on a run; 5 group map unsaved or a tag
# lost; 6 a harness with no auto instance. The lowest applicable code wins.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
mode=run harnesses=()
while (($#)); do
  case $1 in
    --mode) mode=${2:?--mode needs run|continue|report|close}; shift 2 ;;
    --harness) harnesses+=("${2:?--harness needs a name}"); shift 2 ;;
    *) sed -n '2,11p' "$0"; exit 1 ;;
  esac
done
case $mode in run|continue|report|close) ;; *) echo "preflight.sh: unknown mode $mode" >&2; exit 1 ;; esac
((${#harnesses[@]})) || harnesses=(claude)

errors=() code=0
fail() { errors+=("$1"); }
raise() { ((code == 0 || $1 < code)) && code=$1; return 0; }
has() { command -v "$1" >/dev/null 2>&1; }

# --- tools -------------------------------------------------------------------------------------
cli=$(command -v superset || command -v paradev || command -v pdev || true)
version=""
[[ -n $cli ]] && version=$("$cli" --version 2>/dev/null | head -n1 | tr -d '\r')
tools='{}'
for t in bash jq git gh; do
  if has "$t"; then v=true; else v=false; fi
  tools="$tools|$t=$v"
done
if ! has jq; then
  echo '{"error":"jq not found"}'; exit 1
fi
tools=$(jq -nc --arg s "$tools" --arg cli "${cli##*/}" --arg v "$version" '
  ($s | split("|")[1:] | map(split("=") | {(.[0]): (.[1] == "true")}) | add) +
  {paradev: ($cli != ""), paradevCli: (if $cli == "" then null else $cli end),
   paradevVersion: (if $v == "" then null else $v end)}')
for t in bash git gh; do has "$t" || fail "$t not found"; done
[[ -n $cli ]] || fail "Paradev CLI not found: install superset, paradev or pdev"
if ! has git || ! has gh || [[ -z $cli ]]; then
  jq -nc --argjson tools "$tools" --argjson e "$(printf '%s\n' "${errors[@]}" | jq -R . | jq -sc .)" \
    '{tools: $tools, error: ($e | join("; "))}'
  exit 1
fi

# --- auth and host -----------------------------------------------------------------------------
gh_ok=false; gh auth status >/dev/null 2>&1 && gh_ok=true
who=$("$cli" auth whoami --json 2>/dev/null) && who_ok=true || { who_ok=false; who=null; }
jq -e . >/dev/null 2>&1 <<<"$who" || who=null
auth=$(jq -nc --argjson gh "$gh_ok" --argjson p "$who_ok" --argjson who "$who" '{gh: $gh, paradev: $p, whoami: $who}')
$gh_ok || fail "gh is not signed in (gh auth login)"
$who_ok || fail "Paradev is not signed in (superset auth login)"

host_ok=false
snap=$("$cli" snapshot --json 2>/dev/null) && jq -e . >/dev/null 2>&1 <<<"$snap" && host_ok=true
host=$(jq -nc --argjson r "$host_ok" '{reachable: $r}')
$host_ok || fail "Paradev host unreachable (snapshot failed); see superset:doctor, never start it from here"

# --- repo --------------------------------------------------------------------------------------
repo=null
if rv=$(gh repo view --json nameWithOwner,defaultBranchRef,squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed 2>/dev/null) &&
   jq -e .nameWithOwner >/dev/null 2>&1 <<<"$rv"; then
  repo=$(jq -c '{nameWithOwner, defaultBranch: .defaultBranchRef.name,
    mergeMethods: [(if .squashMergeAllowed then "squash" else empty end),
                   (if .mergeCommitAllowed then "merge" else empty end),
                   (if .rebaseMergeAllowed then "rebase" else empty end)]}' <<<"$rv")
else
  raise 2
fi
slug=$(jq -r '.nameWithOwner // empty' <<<"$repo" 2>/dev/null)
name=${slug#*/}

# --- project -----------------------------------------------------------------------------------
project=null project_id=""
if [[ -n $slug ]] && projects=$("$cli" projects list --local --json 2>/dev/null) && jq -e . >/dev/null 2>&1 <<<"$projects"; then
  project=$(jq -c --arg n "$name" '
    (if type == "array" then . else (.projects // []) end) as $p
    | [$p[] | select((.name // "" | ascii_downcase) == ($n | ascii_downcase) or (.repoName // "" | ascii_downcase) == ($n | ascii_downcase))] as $m
    | if ($m | length) >= 1 then {id: $m[0].id, name: $m[0].name}
      else {id: null, candidates: [$p[] | {id, name}]} end' <<<"$projects")
  project_id=$(jq -r '.id // empty' <<<"$project")
fi
[[ -n $project_id ]] || raise 2

# --- plan --------------------------------------------------------------------------------------
plan=null plan_file=""
if [[ -n $slug ]]; then
  plan_file=$("$here/plan.sh" path 2>/dev/null)
  if [[ $mode == report ]]; then
    plan=$(jq -nc --arg p "$plan_file" --arg c "$("$here/plan.sh" check 2>/dev/null)" '{path: $p, check: $c}')
  else
    args=(claim); takeover=false
    out=$("$here/plan.sh" "${args[@]}" 2>/dev/null); rc=$?
    if ((rc == 4)) && [[ $mode == continue ]]; then
      out=$("$here/plan.sh" claim --takeover 2>/dev/null); rc=$?; takeover=true
    fi
    first=$(head -n1 <<<"$out")
    rest=$(tail -n +2 <<<"$out")
    case $rc in
      0)
        if $takeover; then
          plan=$(jq -nc --arg p "$plan_file" --arg t "$first" '{path: $p, claim: "taken-over", takenOver: true, detail: $t}')
        else
          carry=null; [[ -n $rest ]] && jq -e . >/dev/null 2>&1 <<<"$rest" && carry=$(jq -c '.carryOver' <<<"$rest")
          plan=$(jq -nc --arg p "$plan_file" --arg c "$first" --argjson co "$carry" \
            '{path: $p, claim: $c} + (if $co != null then {carryOver: $co} else {} end)')
        fi ;;
      3) plan=$(jq -nc --arg p "$plan_file" --argjson o "$(jq -c . <<<"$out" 2>/dev/null || echo null)" '{path: $p, claim: "live-owner", owner: $o}')
         raise 3 ;;
      4) plan=$(jq -nc --arg p "$plan_file" --argjson o "$(jq -c . <<<"$out" 2>/dev/null || echo null)" '{path: $p, claim: "stale", owner: $o}')
         raise 4 ;;
      *) plan=$(jq -nc --arg p "$plan_file" '{path: $p, claim: "error"}'); fail "plan.sh claim failed" ;;
    esac
  fi
fi

# --- groups ------------------------------------------------------------------------------------
groups=null
if [[ $mode != close && -n $project_id ]]; then
  map="" unsaved=false
  if [[ -f $plan_file ]] && jq -e '.groups | type == "object"' "$plan_file" >/dev/null 2>&1; then
    map=$("$here/groups.sh" "$project_id" plan "$plan_file" 2>/dev/null)
  else
    map=$("$here/groups.sh" "$project_id" 2>/dev/null); rc=$?
    if ((rc == 2)); then unsaved=true; map=$("$here/groups.sh" "$project_id" suggest 2>/dev/null); fi
  fi
  if [[ -n $map ]]; then
    lost=$("$here/groups.sh" "$project_id" check "$map" 2>/dev/null); rc=$?
    ((rc == 5)) && raise 5
    $unsaved && raise 5
    jq -e . >/dev/null 2>&1 <<<"$lost" || lost='{}'
    groups=$(jq -nc --argjson m "$map" --argjson u "$unsaved" --argjson l "$lost" \
      '{map: $m} + (if $u then {unsaved: true} else {} end) + {lost: $l}')
  fi
fi

# --- presets -----------------------------------------------------------------------------------
# An auto instance: the harness's presetId with "(auto)" in the label, claude --permission-mode
# auto, or codex --approve-for-me. Any other instance is regular; one that auto-approves by its
# args is flagged.
presets=null
if $host_ok && agents=$("$cli" agents list --local --json 2>/dev/null) && jq -e . >/dev/null 2>&1 <<<"$agents"; then
  hs=$(printf '%s\n' "${harnesses[@]}" | jq -R . | jq -sc .)
  presets=$(jq -c --argjson hs "$hs" '
    def args_auto: ((.args // []) | join(" ")) | test("--permission-mode[= ]auto|--approve-for-me");
    def labelled: (.label // "") | test("\\(auto\\)"; "i");
    def kind($h): if labelled then "auto-label"
      elif args_auto then (if .presetId == $h then "regular-auto-approves" else "auto-args" end)
      else "regular" end;
    (if type == "array" then . else (.agents // []) end) as $all
    | reduce $hs[] as $h ({};
        ([$all[] | select((.presetId // "" | ascii_downcase | startswith($h)) or (.command // "" | ascii_downcase | contains($h)))
          | {presetId, label, kind: kind($h)}]) as $mine
        | .[$h] = {auto: [$mine[] | select(.kind | startswith("auto")) | {presetId, label, by: (.kind | sub("auto-"; ""))}],
                   regular: [$mine[] | select(.kind | startswith("regular")) | {presetId, label, autoApproves: (.kind == "regular-auto-approves")}]})' <<<"$agents" 2>/dev/null) || presets=null
fi
if [[ $presets != null && $mode != report && $mode != close ]]; then
  jq -e 'to_entries | all(.value.auto | length > 0)' <<<"$presets" >/dev/null 2>&1 || raise 6
fi

# --- output ------------------------------------------------------------------------------------
((${#errors[@]})) && raise 1
errs=$(printf '%s\n' "${errors[@]-}" | jq -R . | jq -sc 'map(select(. != ""))')
jq -nc --argjson tools "$tools" --argjson auth "$auth" --argjson host "$host" --argjson repo "$repo" \
  --argjson project "$project" --argjson plan "$plan" --argjson groups "$groups" --argjson presets "$presets" \
  --argjson errs "$errs" --argjson code "$code" --arg mode "$mode" \
  '{mode: $mode, tools: $tools, auth: $auth, host: $host, repo: $repo, project: $project, plan: $plan,
    groups: $groups, presets: $presets, exit: $code} + (if ($errs | length) > 0 then {error: ($errs | join("; "))} else {} end)'
exit "$code"
