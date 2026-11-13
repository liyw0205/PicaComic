#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT HUP INT TERM
: "${JAVA_HOME:?Set JAVA_HOME to a JDK installation}"
${CC:-cc} -shared -fPIC -Wall -Wextra -Werror -DPICA_USE_LIBCURL=1 \
  -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/linux" \
  -I"$root/android/app/src/main/cpp/include" \
  "$root/android/app/src/main/cpp/pica_curl.c" \
  $(pkg-config --cflags --libs libcurl) -o "$build/libpica_curl.so"
"$JAVA_HOME/bin/keytool" -genkeypair -alias server -keyalg RSA -keysize 2048 \
  -dname CN=localhost -validity 1 -storetype PKCS12 -storepass changeit \
  -keystore "$build/server.p12" >/dev/null 2>&1
"$JAVA_HOME/bin/javac" -d "$build" "$root/test/native_curl/NativeCurl.java"
"$JAVA_HOME/bin/java" -cp "$build" com.github.pacalini.pica_comic.NativeCurl \
  "$build/libpica_curl.so" "$build/server.p12"
