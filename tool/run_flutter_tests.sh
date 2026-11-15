#!/usr/bin/env bash
set -euo pipefail

# Keep the default serial because a few suites exercise process-wide singletons
# and storage overrides. Once those suites are isolated, CI/local runs can opt
# into parallel jobs without changing the workflow.
jobs="${FLUTTER_TEST_CONCURRENCY:-1}"
if ! [[ "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "FLUTTER_TEST_CONCURRENCY must be a positive integer" >&2
  exit 2
fi

exec flutter test --no-pub --concurrency="$jobs" --fail-fast "$@"
