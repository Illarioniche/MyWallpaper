#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/.build/wallpaper-library-probe"
if [[ $# -eq 1 && "$1" == "--build-only" ]]; then
    BUILD_ONLY=true
elif [[ $# -ge 1 && $# -le 2 && "$1" != --* ]]; then
    BUILD_ONLY=false
else
    echo "Usage: $0 --build-only | <local-video> [output-directory]" >&2
    echo "Temporarily displays muted video in test-owned desktop windows with isolated preferences and media storage." >&2
    echo "Never changes system wallpaper, login items, existing libraries or the original video." >&2
    exit 2
fi
mkdir -p "$OUTPUT_DIR" "$PROJECT_ROOT/.build/ModuleCache"
sources=()
for source in "$PROJECT_ROOT"/Sources/MyWallpaper/*.swift; do
    if [[ "${source##*/}" != "MyWallpaperApp.swift" ]]; then sources+=("$source"); fi
done
xcrun swiftc -parse-as-library -swift-version 6 \
    -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
    "${sources[@]}" "$PROJECT_ROOT/Tests/Integration/WallpaperLibraryProbe.swift" \
    -o "$OUTPUT_DIR/wallpaper-library-probe"
if [[ "$BUILD_ONLY" == true ]]; then
    echo "Built $OUTPUT_DIR/wallpaper-library-probe"
    exit 0
fi
exec "$OUTPUT_DIR/wallpaper-library-probe" "$1" "${2:-$OUTPUT_DIR}"
