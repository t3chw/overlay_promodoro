#!/bin/bash
# Builds each spike source into a minimal .app bundle. Bundling matters here:
# unbundled binaries get subtly different window-server treatment.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build

bundle() {
  local name="$1" src="$2" bid="$3" agent="$4"
  local app="build/$name.app"
  mkdir -p "$app/Contents/MacOS"
  swiftc -O -swift-version 5 -o "$app/Contents/MacOS/$name" "src/$src"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bid</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><$agent/>
</dict></plist>
PLIST
  codesign --force --sign - "$app" 2>/dev/null || echo "  (ad-hoc signing skipped for $name)"
  echo "built $app"
}

bundle FloatingSpike    FloatingSpike.swift    dev.spike.floating true
bundle FullScreenTester FullScreenTester.swift dev.spike.tester   false
