#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/.build"
APP_PATH="$PROJECT_ROOT/dist/MyWallpaper.app"

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

swift build "${BUILD_OPTIONS[@]}" --product MyWallpaper
BIN_PATH="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/MyWallpaper" "$APP_PATH/Contents/MacOS/MyWallpaper"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
chmod +x "$APP_PATH/Contents/MacOS/MyWallpaper"

xcrun swift "$PROJECT_ROOT/scripts/generate-icon.swift" "$BUILD_ROOT/MyWallpaper.iconset" "$APP_PATH/Contents/Resources/AppIcon.icns"

/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"

printf '\nГотово: %s\n' "$APP_PATH"
printf 'Запуск: open "%s"\n' "$APP_PATH"
