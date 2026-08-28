#!/bin/bash
# Compiles the sources into a self-contained Pomodoro.app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Pomodoro.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -o "$APP/Contents/MacOS/Pomodoro" \
  src/Geometry.swift src/ResizeGrip.swift src/Prefs.swift src/Engine.swift src/PomodoroView.swift src/SettingsView.swift src/main.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Pomodoro</string>
  <key>CFBundleIdentifier</key><string>dev.local.pomodoro</string>
  <key>CFBundleName</key><string>Pomodoro</string>
  <key>CFBundleDisplayName</key><string>Pomodoro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || echo "  (ad-hoc signing skipped)"
echo "built $APP"
