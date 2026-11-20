#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/.build"
SAVER_PATH="$BUILD_ROOT/MyWallpaper.saver"
SOURCE_PATH="$PROJECT_ROOT/ScreenSaver/MyWallpaperScreenSaverRuntime.m"
PLIST_PATH="$PROJECT_ROOT/ScreenSaver/Info.plist"
APP_PLIST="$PROJECT_ROOT/Resources/Info.plist"

usage() {
    cat <<'EOF'
Usage: ./scripts/build-screensaver.sh [--universal]

Собирает шаблон .build/MyWallpaper.saver без видео и без установки в macOS.
По умолчанию — архитектура текущего Mac; --universal — arm64 и x86_64.
EOF
}

if [[ $# -gt 1 ]]; then usage >&2; exit 2; fi
case "${1:-}" in
    "") ARCHITECTURES=("$(uname -m)") ;;
    --universal) ARCHITECTURES=(arm64 x86_64) ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

if ! xcrun --find clang >/dev/null 2>&1; then
    echo "Нужны инструменты разработчика Apple: xcode-select --install" >&2
    exit 1
fi
for source in "$SOURCE_PATH" "$PLIST_PATH" "$APP_PLIST"; do
    if [[ ! -f "$source" ]]; then
        printf 'Не найден исходный файл: %s\n' "$source" >&2
        exit 1
    fi
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST")"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PLIST")"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BUILD_ROOT/ModuleCache"
WORK_DIR="$(mktemp -d "$BUILD_ROOT/screensaver-build.XXXXXX")"
STAGED_SAVER="$WORK_DIR/MyWallpaper.saver"

cleanup() {
    local status=$?
    trap - EXIT
    # Restore the previous template if replacement was interrupted.
    if [[ ! -e "$SAVER_PATH" && -e "$WORK_DIR/previous.saver" ]]; then
        mv "$WORK_DIR/previous.saver" "$SAVER_PATH" || exit 1
    fi
    rm -rf -- "$WORK_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$STAGED_SAVER/Contents/MacOS" "$STAGED_SAVER/Contents/Resources"
cp "$PLIST_PATH" "$STAGED_SAVER/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $BUILD_VERSION" \
    -c "Set :LSMinimumSystemVersion $MINIMUM_MACOS" "$STAGED_SAVER/Contents/Info.plist"

BINARIES=()
for architecture in "${ARCHITECTURES[@]}"; do
    case "$architecture" in arm64|x86_64) ;; *) echo "Неподдерживаемая архитектура: $architecture" >&2; exit 1 ;; esac
    binary="$WORK_DIR/MyWallpaperScreenSaver-$architecture"
    # The runtime registers a unique principal class from each exported plist.
    # No static custom Objective-C/Swift classes collide in the system host.
    xcrun clang -fobjc-arc -fvisibility=hidden -std=gnu11 -O2 -Wall -Wextra -bundle \
        -isysroot "$SDK_PATH" -arch "$architecture" -mmacosx-version-min="$MINIMUM_MACOS" \
        -framework AppKit -framework ScreenSaver -framework AVFoundation -framework IOKit \
        -framework QuartzCore -framework CoreMedia \
        "$SOURCE_PATH" -o "$binary"
    if ! xcrun otool -hv "$binary" | awk '$5 == "BUNDLE" { found = 1 } END { exit !found }'; then
        echo 'Компилятор не создал Mach-O bundle.' >&2
        exit 1
    fi
    BINARIES+=("$binary")
done

EXECUTABLE="$STAGED_SAVER/Contents/MacOS/MyWallpaperScreenSaver"
if [[ ${#BINARIES[@]} -eq 2 ]]; then
    xcrun lipo -create "${BINARIES[@]}" -output "$EXECUTABLE"
else
    cp "${BINARIES[0]}" "$EXECUTABLE"
fi
chmod +x "$EXECUTABLE"
xcrun lipo "$EXECUTABLE" -verify_arch "${ARCHITECTURES[@]}"
/usr/bin/plutil -lint "$STAGED_SAVER/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$STAGED_SAVER"
/usr/bin/codesign --verify --strict "$STAGED_SAVER"

# Replace the whole generated bundle so old exported media cannot enter a template.
if [[ -e "$SAVER_PATH" || -L "$SAVER_PATH" ]]; then
    mv "$SAVER_PATH" "$WORK_DIR/previous.saver"
fi
mv "$STAGED_SAVER" "$SAVER_PATH"
printf '\nГотов шаблон заставки: %s\n' "$SAVER_PATH"
