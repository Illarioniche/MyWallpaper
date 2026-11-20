#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/.build/screensaver-probe"

if [[ $# -eq 1 && "$1" == "--build-only" ]]; then
    BUILD_ONLY=true
elif [[ $# -eq 2 && ( "$2" == "animated" || "$2" == "static" || "$2" == "invalid" ) ]]; then
    BUILD_ONLY=false
else
    echo "Usage: $0 --build-only | <exported.saver> <animated|static|invalid>" >&2
    echo "The probe loads one bundle in unordered test windows; it never installs a saver or locks the Mac." >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR" "$OUTPUT_DIR/ModuleCache"
xcrun swiftc -parse-as-library -swift-version 6 \
    -module-cache-path "$OUTPUT_DIR/ModuleCache" \
    -framework AppKit -framework ScreenSaver -framework AVFoundation \
    "$PROJECT_ROOT/Tests/Integration/ScreenSaverProbe.swift" \
    -o "$OUTPUT_DIR/screensaver-probe"

if [[ "$BUILD_ONLY" == true ]]; then
    echo "Built $OUTPUT_DIR/screensaver-probe"
    exit 0
fi

exec "$OUTPUT_DIR/screensaver-probe" "$1" "$2"
