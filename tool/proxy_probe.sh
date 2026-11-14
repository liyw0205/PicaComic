#!/bin/sh

# Fill this when you want to run without an argument, for example:
# PROXY_URL="http://127.0.0.1:7890"
# PROXY_URL="socks5://127.0.0.1:10808"
PROXY_URL="${PROXY_URL:-}"

CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-6}"
MAX_TIME="${MAX_TIME:-20}"

if [ -n "$1" ]; then
  PROXY_URL="$1"
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found"
  exit 1
fi

if [ -z "$PROXY_URL" ]; then
  echo "Usage: $0 <proxy>"
  echo "Example:"
  echo "  $0 http://127.0.0.1:7890"
  echo "  $0 socks5://127.0.0.1:10808"
  echo "  PROXY_URL=http://127.0.0.1:7890 $0"
  echo ""
  echo "If no scheme is provided, both HTTP and SOCKS5 will be tested:"
  echo "  $0 127.0.0.1:7890"
  exit 2
fi

has_scheme() {
  case "$1" in
    *://*) return 0 ;;
    *) return 1 ;;
  esac
}

# Credentials can be present in a proxy URI or in a curl diagnostic. Keep
# probe output safe to paste into logs while passing the original value to
# curl.
redact_text() {
  printf '%s\n' "$1" |
    sed -E 's#([[:alpha:]][[:alnum:]+.-]*://)[^[:space:]/@]*@#\1<redacted>@#g'
}

proxy_for_curl() {
  case "$1" in
    socks5://*) printf '%s\n' "socks5h://${1#socks5://}" ;;
    socks5h://*) printf '%s\n' "$1" ;;
    http://*|https://*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "http://$1" ;;
  esac
}

probe() {
  name="$1"
  url="$2"
  proxy="$3"

  result="$(curl \
    --silent \
    --show-error \
    --location \
    --output /dev/null \
    --proxy "$proxy" \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    --write-out "code=%{http_code} connect=%{time_connect}s tls=%{time_appconnect}s first_byte=%{time_starttransfer}s total=%{time_total}s remote=%{remote_ip} err=%{errormsg}" \
    "$url" 2>&1)"
  status="$?"
  safe_result="$(redact_text "$result")"

  if [ "$status" -eq 0 ]; then
    printf '%-12s OK   %s\n' "$name" "$safe_result"
  else
    printf '%-12s FAIL exit=%s %s\n' "$name" "$status" "$safe_result"
  fi
}

run_suite() {
  label="$1"
  raw_proxy="$2"
  proxy="$(proxy_for_curl "$raw_proxy")"

  echo "== $label =="
  echo "proxy: $(redact_text "$proxy")"
  probe "cf-http-204" "http://cp.cloudflare.com/generate_204" "$proxy"
  probe "gstatic-204" "https://www.gstatic.com/generate_204" "$proxy"
  probe "gstatic-http" "http://www.gstatic.com/generate_204" "$proxy"
  probe "android-204" "https://connectivitycheck.gstatic.com/generate_204" "$proxy"
  probe "google-204" "https://www.google.com/generate_204" "$proxy"
  probe "cf-trace" "https://www.cloudflare.com/cdn-cgi/trace" "$proxy"
  probe "example" "https://example.com/" "$proxy"
  probe "e-hentai" "https://e-hentai.org/" "$proxy"
  probe "nhentai" "https://nhentai.net/" "$proxy"
  probe "hitomi" "https://hitomi.la/" "$proxy"
  echo ""
}

echo "Proxy probe"
echo "connect_timeout=${CONNECT_TIMEOUT}s max_time=${MAX_TIME}s"
echo ""

if has_scheme "$PROXY_URL"; then
  run_suite "configured" "$PROXY_URL"
else
  run_suite "as HTTP" "http://$PROXY_URL"
  run_suite "as SOCKS5" "socks5://$PROXY_URL"
fi
