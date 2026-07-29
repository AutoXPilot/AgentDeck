#!/bin/sh
# Runs the test suite.
#
# With Command Line Tools only (no Xcode), Testing.framework lives outside
# SwiftPM's default search path and its _Testing_Foundation cross-import
# overlay ships without a Swift module — hence the explicit flags. With a
# full Xcode toolchain (e.g. CI runners), plain `swift test` works.
set -e
FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$FRAMEWORKS/Testing.framework" ] && ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    exec swift test \
      -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
      -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
      -Xlinker -F -Xlinker "$FRAMEWORKS" \
      -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
      "$@"
fi
exec swift test "$@"
