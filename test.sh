#!/bin/bash
# Engine + preferences tests. Runs against throwaway UserDefaults suites, so
# your real settings are never touched.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -o build/enginetests src/Geometry.swift src/ResizeGrip.swift src/Prefs.swift src/Tasks.swift src/Engine.swift src/PomodoroView.swift src/TaskDrawer.swift tests/main.swift
./build/enginetests
