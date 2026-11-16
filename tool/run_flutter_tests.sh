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

run_performance="${FLUTTER_TEST_PERFORMANCE:-0}"
if [[ "$run_performance" != 0 && "$run_performance" != 1 ]]; then
  echo "FLUTTER_TEST_PERFORMANCE must be 0 or 1" >&2
  exit 2
fi
if [[ "$run_performance" == 1 ]]; then
  # Long-running database benchmarks stay out of release regression runs.
  export PICA_RUN_PERF_TESTS=1
fi

flutter_args=("$@")

# Local iteration can select the affected suites without changing the full
# tag gate. Values are whitespace-separated paths; duplicate paths are removed
# so a shell-expanded list cannot run the same suite twice.
if [[ -n "${FLUTTER_TEST_FILES:-}" ]]; then
  read -r -a requested_files <<<"$FLUTTER_TEST_FILES"
  declare -A seen_files=()
  for file in "${requested_files[@]}"; do
    if [[ "$file" != test/*.dart || ! -f "$file" ]]; then
      echo "FLUTTER_TEST_FILES contains a missing or non-test Dart file: $file" >&2
      exit 2
    fi
    if [[ -z "${seen_files[$file]+x}" ]]; then
      flutter_args+=("$file")
      seen_files["$file"]=1
    fi
  done
fi

if [[ -n "${FLUTTER_TEST_NAME:-}" ]]; then
  flutter_args+=(--name "$FLUTTER_TEST_NAME")
fi

exec flutter test --no-pub --concurrency="$jobs" --fail-fast "${flutter_args[@]}"
