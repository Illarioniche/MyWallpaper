#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/.build"
APP_PATH="$PROJECT_ROOT/dist/MyWallpaper.app"

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--universal" ) ]]; then
    echo "Usage: $0 [--universal]" >&2
    exit 2
fi

if ! xcrun --find swift >/dev/null 2>&1; then
    echo "Нужны инструменты разработчика Apple. Установите их: xcode-select --install" >&2
    exit 1
fi

mkdir -p "$BUILD_ROOT/ModuleCache" "$BUILD_ROOT/cache" "$BUILD_ROOT/config" "$BUILD_ROOT/security"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/ModuleCache"

BUILD_OPTIONS=(
    --package-path "$PROJECT_ROOT"
    --scratch-path "$BUILD_ROOT"
    --cache-path "$BUILD_ROOT/cache"
    --config-path "$BUILD_ROOT/config"
    --security-path "$BUILD_ROOT/security"
    --disable-sandbox
    -c release
)

BINARIES=()
if [[ "${1:-}" == "--universal" ]]; then
    for architecture in arm64 x86_64; do
        triple="$architecture-apple-macosx13.0"
        swift build "${BUILD_OPTIONS[@]}" --triple "$triple" --product MyWallpaper
        BIN_PATH="$(swift build "${BUILD_OPTIONS[@]}" --triple "$triple" --show-bin-path)"
        BINARIES+=("$BIN_PATH/MyWallpaper")
    done
else
    swift build "${BUILD_OPTIONS[@]}" --product MyWallpaper
    BIN_PATH="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
    BINARIES+=("$BIN_PATH/MyWallpaper")
fi

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
# Replace the executable atomically so rebuilding does not truncate a running
# copy's mapped binary. The running app keeps its old version until relaunched.
if [[ ${#BINARIES[@]} -eq 2 ]]; then
    xcrun lipo -create "${BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/.MyWallpaper.new"
    xcrun lipo "$APP_PATH/Contents/MacOS/.MyWallpaper.new" -verify_arch arm64 x86_64
else
    cp "${BINARIES[0]}" "$APP_PATH/Contents/MacOS/.MyWallpaper.new"
fi
chmod +x "$APP_PATH/Contents/MacOS/.MyWallpaper.new"
mv -f "$APP_PATH/Contents/MacOS/.MyWallpaper.new" "$APP_PATH/Contents/MacOS/MyWallpaper"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"

xcrun swiftc -parse-as-library -swift-version 6 \
    -module-cache-path "$BUILD_ROOT/ModuleCache" \
    "$PROJECT_ROOT/Sources/MyWallpaper/AppIconArtwork.swift" \
    "$PROJECT_ROOT/scripts/generate-icon.swift" \
    -o "$BUILD_ROOT/generate-icon"
"$BUILD_ROOT/generate-icon" "$BUILD_ROOT/MyWallpaper.iconset" \
    "$APP_PATH/Contents/Resources/AppIcon.icns" "$BUILD_ROOT/app-icon-preview1024.png"

/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"

printf '\nГотово: %s\n' "$APP_PATH"
printf 'Запуск: open "%s"\n' "$APP_PATH"
