#!/bin/bash
# Produces a distributable zip of the app.
#
# `ditto` rather than `zip`: it preserves the bundle's extended attributes and
# code signature, which plain zip mangles.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
./build.sh

ZIP="build/Pomodoro-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Pomodoro.app "$ZIP"

echo "packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
shasum -a 256 "$ZIP" | awk '{print "sha256: " $1}'
