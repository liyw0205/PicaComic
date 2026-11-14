#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline="$root/tool/async-boundary-baseline.txt"

count_matches() {
  local pattern="$1"
  local matches
  if command -v rg >/dev/null 2>&1; then
    matches="$(rg --pcre2 -n "$pattern" "$root/lib" 2>/dev/null || true)"
  elif command -v grep >/dev/null 2>&1; then
    # GitHub-hosted runners normally include ripgrep, but the check should
    # remain usable on minimal CI images and local release environments.
    matches="$(grep -R -P -n --include='*.dart' "$pattern" "$root/lib" 2>/dev/null || true)"
  else
    echo 'Neither rg nor grep is available for async-boundary scanning.' >&2
    exit 2
  fi
  if [[ -z "$matches" ]]; then
    printf '0\n'
  else
    printf '%s\n' "$matches" | wc -l | tr -d ' '
  fi
}

void_async="$(count_matches '^\s*(?:(?:static|abstract|external)\s+)*void\s+[^;{]*\basync\b')"
future_void_async="$(count_matches '^\s*(?:(?:static|abstract|external)\s+)*Future<void>\s+[^;{]*\basync\b')"
sync_io="$(count_matches '(readAsBytesSync|readAsStringSync|writeAsBytesSync|writeAsStringSync|listSync|deleteSync|renameSync|copySync)')"

allowed_void_async="$(sed -n 's/^void_async=//p' "$baseline")"
if [[ "$allowed_void_async" =~ ^[0-9]+$ ]] && (( void_async > allowed_void_async )); then
  echo "void async boundary count increased: $void_async/$allowed_void_async" >&2
  exit 1
fi

printf 'async-boundary: void_async=%s (baseline=%s), future_void_async=%s, sync_io=%s\n' \
  "$void_async" "${allowed_void_async:-unset}" "$future_void_async" "$sync_io"
