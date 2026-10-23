#!/bin/bash
# Run a build/test command and, if it fails, republish its first 30 distinct error lines as GitHub
# annotations (10 error + 10 warning + 10 notice: GitHub's per-step caps), so failures are readable
# through the checks API without downloading the full log. Exit status is the command's own.
set -o pipefail
log="$(mktemp)"
"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ]; then
  repo="${GITHUB_WORKSPACE:-$PWD}/"
  grep -E "(error|fatal error): |: error -|XCTAssert[A-Za-z]* failed|Test Case .* failed" "$log" \
    | sed -e "s#${repo}##g" -e 's/^[[:space:]]*//' \
    | awk '!seen[$0]++' \
    | head -30 > "$log.errors"
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    msg="${line//'%'/'%25'}"
    msg="${msg:0:900}"
    if [ $n -le 10 ]; then echo "::error::$msg"
    elif [ $n -le 20 ]; then echo "::warning::$msg"
    else echo "::notice::$msg"; fi
  done < "$log.errors"
fi
exit "$status"
