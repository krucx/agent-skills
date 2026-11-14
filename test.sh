#!/usr/bin/env bash
# Runs every skills/*/scripts/test/run.sh; exits non-zero if any suite fails.
#
#   bash test.sh
set -uo pipefail

root=$(cd "$(dirname "$0")" && pwd)
ran=0 failed=0

for suite in "$root"/skills/*/scripts/test/run.sh; do
  [[ -f $suite ]] || continue
  echo "== ${suite#"$root"/}"
  ran=$((ran + 1))
  bash "$suite" || { failed=$((failed + 1)); echo "FAILED: ${suite#"$root"/}"; }
done

echo
echo "$ran suite(s), $failed failed"
((ran > 0 && failed == 0))
