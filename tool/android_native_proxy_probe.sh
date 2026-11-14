#!/usr/bin/env sh
set -eu

if [ $# -lt 1 ]; then
  echo "Usage: $0 <http://user:pass@host:port> [url ...]" >&2
  exit 2
fi

android_home="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/android-sdk}}"
platform="$(ls -d "$android_home"/platforms/android-* 2>/dev/null | sort -V | tail -1)"
d8_bin="${D8:-$android_home/cmdline-tools/latest/bin/d8}"

if [ ! -f "$platform/android.jar" ]; then
  echo "android.jar not found under $android_home/platforms" >&2
  exit 1
fi

if [ ! -x "$d8_bin" ]; then
  echo "d8 not found at $d8_bin" >&2
  exit 1
fi

runner="${DALVIKVM:-/apex/com.android.art/bin/dalvikvm64}"
if [ ! -x "$runner" ]; then
  runner="/apex/com.android.art/bin/dalvikvm"
fi

tmp="${TMPDIR:-/tmp}/android_native_proxy_probe.$$"
mkdir -p "$tmp/classes" "$tmp/dex"
trap 'rm -rf "$tmp"' EXIT INT TERM

javac -Xlint:-options -source 8 -target 8 -cp "$platform/android.jar" \
  -d "$tmp/classes" "$(dirname "$0")/android_native_proxy_probe/NativeProxyProbe.java"

"$d8_bin" --lib "$platform/android.jar" --output "$tmp/dex" "$tmp/classes"/*.class >/dev/null
chmod 0444 "$tmp/dex/classes.dex"

boot_args=""
if [ -n "${BOOTCLASSPATH:-}" ]; then
  boot_args="-Xbootclasspath:$BOOTCLASSPATH -Xbootclasspath-locations:$BOOTCLASSPATH"
fi

# shellcheck disable=SC2086
"$runner" $boot_args -cp "$tmp/dex/classes.dex" NativeProxyProbe "$@"
