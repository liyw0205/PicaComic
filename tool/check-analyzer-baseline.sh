#!/usr/bin/env bash
set -euo pipefail

baseline="$(dirname "$0")/analyzer-baseline.txt"
output="$(mktemp)"
trap 'rm -f "$output"' EXIT

set +e
dart analyze --format machine lib test >"$output" 2>&1
analyzer_status=$?
set -e

cat "$output"
errors="$(awk -F'|' '$1 == "ERROR" { count++ } END { print count + 0 }' "$output")"
warnings="$(awk -F'|' '$1 == "WARNING" { count++ } END { print count + 0 }' "$output")"
allowed_errors="$(sed -n 's/^errors=//p' "$baseline")"
allowed_warnings="$(sed -n 's/^warnings=//p' "$baseline")"

if [[ -z "$allowed_errors" || -z "$allowed_warnings" ]]; then
  echo "Invalid analyzer baseline: $baseline" >&2
  exit 2
fi
if (( errors > allowed_errors || warnings > allowed_warnings )); then
  echo "Analyzer diagnostics exceed baseline: errors=$errors/$allowed_errors warnings=$warnings/$allowed_warnings" >&2
  exit 1
fi
echo "Analyzer baseline passed: errors=$errors/$allowed_errors warnings=$warnings/$allowed_warnings"
