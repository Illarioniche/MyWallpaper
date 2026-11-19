#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/.build/verification"

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [local-video | --build-only]" >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR" "$PROJECT_DIR/.build/ModuleCache"
sources=()
for source in "$PROJECT_DIR"/Sources/MyWallpaper/*.swift; do
    if [[ "${source##*/}" != "MyWallpaperApp.swift" ]]; then
        sources+=("$source")
    fi
done

xcrun swiftc -parse-as-library -swift-version 6 \
    -module-cache-path "$PROJECT_DIR/.build/ModuleCache" \
    "${sources[@]}" "$PROJECT_DIR/Tests/Preview/RenderUI.swift" \
    -o "$OUTPUT_DIR/render-ui"

if [[ "${1:-}" == "--build-only" ]]; then
    echo "Built $OUTPUT_DIR/render-ui"
    exit 0
fi

exec "$OUTPUT_DIR/render-ui" "$OUTPUT_DIR" "$@"
