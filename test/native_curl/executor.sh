#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT HUP INT TERM
"${JAVA_HOME:+$JAVA_HOME/bin/}javac" -Xlint:all -Werror -d "$build" \
  "$root/android/app/src/main/kotlin/com/github/pacalini/pica_comic/NativeCurlExecutor.java" \
  "$root/test/native_curl/NativeCurlExecutorTest.java"
"${JAVA_HOME:+$JAVA_HOME/bin/}java" -cp "$build" \
  com.github.pacalini.pica_comic.NativeCurlExecutorTest
