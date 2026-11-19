#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/.build/readme"

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--prepare-only" && "$1" != "--copy-images" ) ]]; then
    echo "Usage: $0 [--prepare-only | --copy-images]" >&2
    exit 2
fi

# Copy only the four reviewed README assets; never replace the verification renders.
if [[ "${1:-}" == "--copy-images" ]]; then
    for source in "$OUTPUT_DIR/app-icon.png" \
        "$OUTPUT_DIR/ui/ui-wallpaper-light.png" \
        "$OUTPUT_DIR/ui/ui-wallpaper-dark.png" \
        "$OUTPUT_DIR/ui/ui-power-light.png"; do
        [[ -f "$source" ]] || { echo "Missing prepared image: $source" >&2; exit 1; }
    done
    mkdir -p "$PROJECT_DIR/docs/images"
    cp "$OUTPUT_DIR/app-icon.png" "$PROJECT_DIR/docs/images/app-icon.png"
    cp "$OUTPUT_DIR/ui/ui-wallpaper-light.png" "$PROJECT_DIR/docs/images/wallpaper-light.png"
    cp "$OUTPUT_DIR/ui/ui-wallpaper-dark.png" "$PROJECT_DIR/docs/images/wallpaper-dark.png"
    cp "$OUTPUT_DIR/ui/ui-power-light.png" "$PROJECT_DIR/docs/images/power-light.png"
    echo "Copied four reviewed images to docs/images."
    exit 0
fi

mkdir -p "$OUTPUT_DIR/ui" "$PROJECT_DIR/.build/ModuleCache"
xcrun swiftc -parse-as-library -swift-version 6 \
    -module-cache-path "$PROJECT_DIR/.build/ModuleCache" \
    "$SCRIPT_DIR/generate-demo-video.swift" -o "$OUTPUT_DIR/generate-demo-video"
"$OUTPUT_DIR/generate-demo-video" "$OUTPUT_DIR"

xcrun swiftc -parse-as-library -swift-version 6 \
    -module-cache-path "$PROJECT_DIR/.build/ModuleCache" \
    "$PROJECT_DIR/Sources/MyWallpaper/AppIconArtwork.swift" "$SCRIPT_DIR/generate-icon.swift" \
    -o "$OUTPUT_DIR/generate-icon"
"$OUTPUT_DIR/generate-icon" "$OUTPUT_DIR/iconset" \
    "$OUTPUT_DIR/AppIcon.icns" "$OUTPUT_DIR/app-icon-preview1024.png"
cp "$OUTPUT_DIR/iconset/icon_128x128@2x.png" "$OUTPUT_DIR/app-icon.png"

"$SCRIPT_DIR/render-ui.sh" --build-only
if [[ "${1:-}" == "--prepare-only" ]]; then
    echo "Prepared original Aurora.mp4, app icon and UI renderer in .build/readme."
    exit 0
fi

# The renderer keeps its native windows hidden; it never loads desktop wallpaper.
"$PROJECT_DIR/.build/verification/render-ui" "$OUTPUT_DIR/ui" "$OUTPUT_DIR/Aurora.mp4"
echo "Review .build/readme/ui, then run $0 --copy-images."
