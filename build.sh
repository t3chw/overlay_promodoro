#!/bin/bash
# Builds a self-contained, ad-hoc signed Pomodoro.app.
#
# The binary is built universal (arm64 + x86_64) against an explicit macOS 14
# deployment target. Without -target, swiftc targets whatever the build machine
# runs, so a Mac on macOS 26 produces a binary that refuses to launch on 14 no
# matter what LSMinimumSystemVersion claims.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
DEPLOY_TARGET="14.0"
APP="build/Pomodoro.app"
SOURCES=(src/Geometry.swift src/HotKeys.swift src/ResizeGrip.swift src/Prefs.swift
         src/Engine.swift src/PomodoroView.swift src/SettingsView.swift src/main.swift)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

slices=()
for arch in arm64 x86_64; do
  out="build/obj/Pomodoro-$arch"
  if swiftc -O -swift-version 5 \
       -target "${arch}-apple-macos${DEPLOY_TARGET}" \
       -o "$out" "${SOURCES[@]}" 2>/dev/null; then
    slices+=("$out")
  else
    echo "  note: $arch slice unavailable on this toolchain, skipping"
  fi
done

if [ ${#slices[@]} -eq 0 ]; then
  echo "error: no architecture built" >&2
  exit 1
fi
lipo -create -output "$APP/Contents/MacOS/Pomodoro" "${slices[@]}"

cp assets/Pomodoro.icns "$APP/Contents/Resources/Pomodoro.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Pomodoro</string>
  <key>CFBundleIdentifier</key><string>dev.local.pomodoro</string>
  <key>CFBundleName</key><string>Pomodoro</string>
  <key>CFBundleDisplayName</key><string>Pomodoro</string>
  <key>CFBundleIconFile</key><string>Pomodoro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>${DEPLOY_TARGET}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  note: ad-hoc signing skipped"
echo "built $APP (v${VERSION}) — $(lipo -archs "$APP/Contents/MacOS/Pomodoro")"
