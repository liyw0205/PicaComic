#!/usr/bin/env bash
set -euo pipefail

apk_root="build/app/outputs/apk"
output="build/apk-metadata.json"
build_mode=""

while (($# > 0)); do
  case "$1" in
    --apk-root) apk_root="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --build-mode) build_mode="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v unzip >/dev/null
command -v sha256sum >/dev/null
command -v git >/dev/null
if [[ ! -d "$apk_root" ]]; then
  echo "APK output directory does not exist: $apk_root" >&2
  exit 1
fi
if ! find "$apk_root" -type f -name '*.apk' -print -quit | grep -q .; then
  echo "No APK files found under $apk_root" >&2
  exit 1
fi

version_line="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1)"
version_name="$(printf '%s' "$version_line" | cut -d+ -f1)"
version_code="$(printf '%s' "$version_line" | cut -d+ -f2-)"
if [[ "$version_line" != *+* || -z "$version_name" || -z "$version_code" ]]; then
  echo "pubspec.yaml version must be name+code" >&2
  exit 1
fi

commit="$(git rev-parse HEAD)"
flutter_version="$(printenv FLUTTER_VERSION || true)"
flutter_bin="$(command -v flutter || true)"
if [[ -z "$flutter_version" && -n "$flutter_bin" ]]; then
  flutter_version="$(flutter --version --machine 2>/dev/null |
    sed -n 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
fi
if [[ -z "$flutter_version" && -f .flutter-version ]]; then
  flutter_version="$(sed -n '1p' .flutter-version)"
fi
if [[ -z "$flutter_version" ]]; then
  echo "Unable to determine Flutter version" >&2
  exit 1
fi

if [[ -z "$build_mode" ]]; then
  case "$apk_root" in
    *release*) build_mode=release ;;
    *profile*) build_mode=profile ;;
    *) build_mode=debug ;;
  esac
fi

android_home="$(printenv ANDROID_HOME || true)"
apksigner=""
if [[ -n "$android_home" ]]; then
  apksigner="$(find "$android_home/build-tools" -type f -name apksigner 2>/dev/null |
    sort -V | tail -n 1 || true)"
fi
if [[ -z "$apksigner" || ! -x "$apksigner" ]]; then
  echo "Android build-tools apksigner is required" >&2
  exit 1
fi

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

mkdir -p "$(dirname "$output")"
{
  printf '{\n'
  printf '  "schemaVersion": 1,\n'
  printf '  "commit": "%s",\n' "$(json_escape "$commit")"
  printf '  "versionName": "%s",\n' "$(json_escape "$version_name")"
  printf '  "versionCode": "%s",\n' "$(json_escape "$version_code")"
  printf '  "flutterVersion": "%s",\n' "$(json_escape "$flutter_version")"
  printf '  "buildMode": "%s",\n' "$(json_escape "$build_mode")"
  printf '  "generatedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "apks": [\n'
  first_apk=1
  while IFS= read -r apk; do
    name="$(basename "$apk")"
    relative="$(printf '%s' "$apk" | sed 's#^\./##')"
    sha="$(sha256sum "$apk" | awk '{print $1}')"
    size="$(wc -c < "$apk" | tr -d '[:space:]')"

    abis_json='['
    first_abi=1
    while IFS= read -r abi; do
      if ((first_abi == 0)); then abis_json+=','; fi
      abis_json+="\"$(json_escape "$abi")\""
      first_abi=0
    done < <(unzip -Z1 "$apk" | sed -n 's#^lib/\([^/]*\)/.*#\1#p' | sort -u)
    if ((first_abi == 1)); then abis_json+='"universal"'; fi
    abis_json+=']'

    has_pica=0
    has_curl=0
    if unzip -Z1 "$apk" | grep -qE '^lib/[^/]+/libpica_curl\.so$'; then has_pica=1; fi
    if unzip -Z1 "$apk" | grep -qE '^lib/[^/]+/libcurl\.so$'; then has_curl=1; fi
    native_curl=missing
    if ((has_pica && has_curl)); then
      native_curl=native
    elif ((has_pica)); then
      native_curl=fallback
    fi

    signer="$("$apksigner" verify --print-certs "$apk" 2>&1 |
      sed -n 's/.*Signer #1 certificate SHA-256 digest:[[:space:]]*//p' |
      head -n 1 | tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]')"
    if [[ ! "$signer" =~ ^[A-F0-9]{64}$ ]]; then
      echo "Unable to read signer SHA-256 for $apk" >&2
      exit 1
    fi

    if ((first_apk == 0)); then printf ',\n'; fi
    printf '    {"name":"%s","path":"%s","sizeBytes":%s,"sha256":"%s","abis":%s,"nativeCurl":"%s","signerSha256":"%s"}' \
      "$(json_escape "$name")" "$(json_escape "$relative")" "$size" "$sha" \
      "$abis_json" "$native_curl" "$signer"
    first_apk=0
  done < <(find "$apk_root" -type f -name '*.apk' -print | sort)
  printf '\n  ]\n}\n'
} > "$output"

test -s "$output"
printf 'Wrote APK metadata: %s\n' "$output"
