#!/bin/sh
# Runs `swift test` with whichever toolchain works.
# Xcode 27 is preferred. Under the Command Line Tools for macOS 27, SwiftPM can't find
# swift-testing's macro plugin (it moved into plugins/testing/), so we point at it.
set -eu
cd "$(dirname "$0")/.."
XCODE=/Applications/Xcode.app/Contents/Developer
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$XCODE" ]; then
  export DEVELOPER_DIR="$XCODE"
fi
DEV="${DEVELOPER_DIR:-$(xcode-select -p)}"
PLUGINS="$DEV/usr/lib/swift/host/plugins/testing"
if [ ! -d "$PLUGINS" ]; then
  PLUGINS="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
fi
if [ -d "$PLUGINS" ] && ! [ -d "$DEV/Toolchains" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
