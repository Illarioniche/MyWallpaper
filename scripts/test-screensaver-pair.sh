#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/.build/screensaver-pair-probe"

if [[ $# -eq 1 && "$1" == "--build-only" ]]; then
    BUILD_ONLY=true
elif [[ $# -eq 2 ]]; then
    BUILD_ONLY=false
else
    echo "Usage: $0 --build-only | <static.saver> <animated.saver>" >&2
    echo "Use different identities, scaling modes and poster images. Static: both power sources off. Animated: both on, low-power pause off." >&2
    echo "The probe loads both bundles in one process with unordered windows. It never installs savers or locks the Mac." >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR/ModuleCache"
xcrun swiftc -parse-as-library -swift-version 6 \
    -module-cache-path "$OUTPUT_DIR/ModuleCache" \
    -framework AppKit -framework ScreenSaver -framework AVFoundation \
    "$PROJECT_ROOT/Tests/Integration/TwoScreenSaverProbe.swift" \
    -o "$OUTPUT_DIR/screensaver-pair-probe"

if [[ "$BUILD_ONLY" == true ]]; then
    echo "Built $OUTPUT_DIR/screensaver-pair-probe"
    exit 0
fi

exec "$OUTPUT_DIR/screensaver-pair-probe" "$1" "$2"
