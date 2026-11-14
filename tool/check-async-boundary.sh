#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline="$root/tool/async-boundary-baseline.txt"

count_matches() {
  local pattern="$1"
  rg --pcre2 -n "$pattern" "$root/lib" 2>/dev/null | wc -l | tr -d ' '
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
