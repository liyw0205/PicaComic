#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <current-ref> <output-file>" >&2
  exit 2
fi

current_ref="$1"
output_file="$2"
current_commit="$(git rev-parse "${current_ref}^{commit}")"
previous_tag="$(git describe --tags --match 'v*' --abbrev=0 \
  "${current_commit}^" 2>/dev/null || true)"

{
  if [[ -n "$previous_tag" ]]; then
    printf 'Changes since `%s`:\n' "$previous_tag"
    git log --no-merges --pretty=format:'- %h %s' \
      "${previous_tag}..${current_commit}"
    printf '\n'
  else
    printf 'Changes in this release:\n'
    git log --no-merges --pretty=format:'- %h %s' "$current_commit"
    printf '\n'
  fi
} > "$output_file"
