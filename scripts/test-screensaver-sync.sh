#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/.build/screensaver-sync-probe"
if [[ $# -eq 1 && "$1" == "--build-only" ]]; then
    BUILD_ONLY=true
elif [[ $# -eq 1 && "$1" != --* ]]; then
    BUILD_ONLY=false
else
    echo "Usage: $0 --build-only | <local-video>" >&2
    echo "Loads temporary linked and ordinary savers in hidden windows; never installs or locks macOS." >&2
    exit 2
fi
mkdir -p "$OUTPUT_DIR" "$PROJECT_ROOT/.build/ModuleCache"
xcrun swiftc -parse-as-library -swift-version 6 \
    -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
    -framework AppKit -framework ScreenSaver -framework AVFoundation \
    "$PROJECT_ROOT/Sources/MyWallpaper/ScreenSaverExporter.swift" \
    "$PROJECT_ROOT/Sources/MyWallpaper/ScreenSaverInstallationIdentity.swift" \
    "$PROJECT_ROOT/Sources/MyWallpaper/ScreenSaverSyncInstallation.swift" \
    "$PROJECT_ROOT/Sources/MyWallpaper/ScreenSaverSyncStore.swift" \
    "$PROJECT_ROOT/Tests/Integration/ScreenSaverSyncProbe.swift" \
    -o "$OUTPUT_DIR/screensaver-sync-probe"
if [[ "$BUILD_ONLY" == true ]]; then
    echo "Built $OUTPUT_DIR/screensaver-sync-probe"
    exit 0
fi
exec "$OUTPUT_DIR/screensaver-sync-probe" "$1" "$PROJECT_ROOT/.build/MyWallpaper.saver" "$OUTPUT_DIR"
