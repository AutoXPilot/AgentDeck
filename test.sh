#!/bin/sh
# Runs the test suite with Command Line Tools (no Xcode).
# CLT ships Testing.framework outside SwiftPM's default search path, and its
# _Testing_Foundation cross-import overlay has no Swift module — hence the
# explicit -F paths and disabled overlays.
set -e
FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  "$@"
