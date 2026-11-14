#!/usr/bin/env sh
set -eu

if [ $# -lt 1 ]; then
  echo "Usage: $0 <proxy> [url ...]" >&2
  exit 2
fi

tmp="${TMPDIR:-/tmp}/libcurl_probe.$$"
trap 'rm -f "$tmp"' EXIT INT TERM

cc ${CFLAGS:-} "$(dirname "$0")/libcurl_probe.c" -o "$tmp" \
  $(pkg-config --cflags --libs libcurl)

"$tmp" "$@"
