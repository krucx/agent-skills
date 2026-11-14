#!/usr/bin/env bash
# Render the run-summary page from the plan alone and publish it (SKILL.md, "Run summary").
#
# Usage: summary.sh <plan-file> [--visibility just_me|org] [--open]   (inside the repo the plan belongs to)
#
# No model text is involved: header, a row per item in plan order grouped by integration, the
# carry-over of a closed run and the events log all come from the plan; every plan field is
# HTML-escaped, as data. Publishes with `pages publish` (adding --page <pageId> when the plan has
# one), stores the returned ID as `pageId` through plan.sh write, prints "<url> (<visibility>)".
# --open also shows it in the Paradev browser pane when the CLI has `panes open browser`.
set -euo pipefail

usage='usage: summary.sh <plan-file> [--visibility just_me|org] [--open]'
plan=${1:?$usage}
shift
visibility=just_me
open=''
while (($#)); do
  case $1 in
    --visibility) visibility=${2:?--visibility needs just_me or org}; shift 2 ;;
    --open) open=1; shift ;;
    *) echo "summary.sh: unknown option $1" >&2; echo "$usage" >&2; exit 1 ;;
  esac
done
[[ $visibility == just_me || $visibility == org ]] || { echo "summary.sh: visibility is just_me or org" >&2; exit 1; }
[[ -f $plan ]] || { echo "summary.sh: no plan file $plan" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
# superset, paradev and pdev are the same Paradev CLI; use whichever is installed.
cli=$(command -v superset || command -v paradev || command -v pdev || true)
[[ -n $cli ]] || { echo "Paradev CLI not found: install superset, paradev or pdev" >&2; exit 1; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/orchestrator-summary.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
html="$scratch/summary.html"

jq -r '
  def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;") | gsub("'"'"'"; "&#39;");
  def val: if . == null or . == "" then "—" else esc end;
  def link: if . == null then "—"
    elif test("^https?://") then "<a href=\"\(esc)\">\(esc)</a>" else esc end;
  def crit: if . == null then "—"
    else "\(.met)/\(.total)" + (if (.unmet | length) > 0
      then "<ul>" + ([.unmet[] | "<li>\(esc)</li>"] | join("")) + "</ul>" else "" end) end;
  (.items // []) as $items
  | (.integrations // []) as $integs
  | def itemrow: "<tr><td>\(.id | val)</td><td>\(.title | val)</td><td>\(.state | val)</td><td>\(.pr | link)</td>"
      + "<td>\(.branch | val)</td><td>\(.checked | val)</td><td>\(.criteria | crit)</td>"
      + "<td>\(if (.acceptance // "ok") == "ok" then "—" else .acceptance | esc end)</td>"
      + "<td>\(.extras | val)</td><td>\(.reason | val)</td></tr>";
    def head($f): "<tr class=\"group\"><td colspan=\"10\"><b>\($f.id | esc) \($f.branch | val)</b> \($f.title | val)"
      + " — \($f.state | val); final PR: \($f.pr | link)</td></tr>";
    ([$items[] | select(.integrates == null) | .state] | group_by(.) | map("\(.[0]): \(length)") | join(", ")) as $counts
  | (reduce $items[] as $it ({out: [], seen: []};
      if $it.integrates != null then .
      elif $it.integration != null and ([$integs[] | select(.id == $it.integration)] | length) > 0 then
        if (.seen | index($it.integration)) then .
        else ([$integs[] | select(.id == $it.integration)][0]) as $f
          | .seen += [$f.id]
          | .out += [head($f)]
            + [$items[] | select(.integration == $f.id) | itemrow]
            + [$items[] | select(.integrates == $f.id) | itemrow]
        end
      else .out += [$it | itemrow] end) | .out) as $rows
  | "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    + "<title>Run \(.runId | val)</title>"
    + "<style>body{font:14px/1.5 system-ui,sans-serif;margin:16px;max-width:1200px}table{border-collapse:collapse;width:100%;display:block;overflow-x:auto}"
    + "th,td{border:1px solid #8885;padding:4px 8px;text-align:left;vertical-align:top}th{background:#8882}tr.group td{background:#8881}</style></head><body>"
    + "<h1>Run \(.runId | val)</h1>"
    + "<p>\(.repo | val) · status: \(.status | val) · \(($items | length)) items (\($counts | val))</p>"
    + "<h2>Items</h2><table><tr><th>Item</th><th>Title</th><th>State</th><th>PR</th><th>Branch</th><th>Checked</th><th>Criteria</th><th>Acceptance gap</th><th>Extras</th><th>Reason</th></tr>"
    + ($rows | join("\n")) + "</table>"
    + (if (.carryOver // []) | length > 0 then
        "<h2>Carry-over</h2><table><tr><th>Item</th><th>State</th><th>Reason</th></tr>"
        + ([.carryOver[] | "<tr><td>\(.id | val)</td><td>\(.state | val)</td><td>\(.reason | val)</td></tr>"] | join("\n")) + "</table>"
      else "" end)
    + "<h2>Events</h2><table><tr><th>At</th><th>Item</th><th>Action</th><th>Detail</th></tr>"
    + ([(.events // [])[] | "<tr><td>\(.at | val)</td><td>\(.item | val)</td><td>\(.action | val)</td><td>\(.detail | val)</td></tr>"] | join("\n"))
    + "</table></body></html>"
' "$plan" >"$html"

page=$(jq -r '.pageId // empty' "$plan")
args=(pages publish "$html" --title "Run $(jq -r '.runId // "unknown"' "$plan")" --visibility "$visibility")
[[ -z $page ]] || args+=(--page "$page")
out=$("$cli" "${args[@]}" --json)

new_id=$(jq -r '.pageId // .id // empty' <<<"$out")
url=$(jq -r '.url // empty' <<<"$out")
if [[ -n $new_id && $new_id != "$page" ]]; then
  jq --arg id "$new_id" '.pageId = $id' "$plan" >"$scratch/plan.json"
  "$here/plan.sh" write "$scratch/plan.json"
fi
echo "${url:-${new_id:-published}} ($visibility)"

if [[ -n $open && -n $url ]] && "$cli" panes open --help >/dev/null 2>&1; then
  "$cli" panes open browser --url "$url" >/dev/null || true
fi
