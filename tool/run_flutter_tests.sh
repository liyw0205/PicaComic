#!/usr/bin/env bash
set -euo pipefail

# Keep the default conservative because a few suites exercise process-wide
# networking and storage overrides. CI and local runs can tune this without
# changing the workflow.
jobs="${FLUTTER_TEST_CONCURRENCY:-2}"
if ! [[ "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "FLUTTER_TEST_CONCURRENCY must be a positive integer" >&2
  exit 2
fi

exec flutter test --no-pub --concurrency="$jobs" --fail-fast "$@"
