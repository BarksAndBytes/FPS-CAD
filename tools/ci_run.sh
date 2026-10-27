#!/usr/bin/env bash
# Runs a CI command, keeping its full output in the job log. On failure it also raises the last
# error lines as GitHub annotations, which stay readable from the pull request's checks page.
#   tools/ci_run.sh <command> [args...]
set -uo pipefail
log="$(mktemp)"
"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ]; then
  grep -E "error|Error|ERROR|FAILED|FAIL |undefined reference|SCRIPT ERROR|Parse Error|Signing|apksigner|Exception|keystore|java" "$log" \
    | tail -n 40 | while IFS= read -r line; do echo "::error::${line//%/%25}"; done
  echo "::error::'$*' failed with exit code $status; last lines:"
  tail -n 15 "$log" | while IFS= read -r line; do echo "::error::${line//%/%25}"; done
fi
rm -f "$log"
exit "$status"
