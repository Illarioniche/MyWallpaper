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
    --disable-keychain
    --disable-netrc
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

# Sparkle is a dynamic framework, including its own installer application and
# XPC services. Keep the vendor's nested signatures and framework symlinks intact;
# signing the outer application seals them without re-signing helpers incorrectly.
SPARKLE_SOURCE="$BUILD_ROOT/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_TARGET="$APP_PATH/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP_PATH/Contents/Frameworks"
/usr/bin/codesign --verify --deep --strict "$SPARKLE_SOURCE"
rm -rf -- "$APP_PATH/Contents/Frameworks/.Sparkle.new.framework"
/usr/bin/ditto "$SPARKLE_SOURCE" "$APP_PATH/Contents/Frameworks/.Sparkle.new.framework"
if [[ -e "$SPARKLE_TARGET" ]]; then
    rm -rf -- "$APP_PATH/Contents/Frameworks/.Sparkle.previous.framework"
    mv "$SPARKLE_TARGET" "$APP_PATH/Contents/Frameworks/.Sparkle.previous.framework"
fi
if ! mv "$APP_PATH/Contents/Frameworks/.Sparkle.new.framework" "$SPARKLE_TARGET"; then
    if [[ -e "$APP_PATH/Contents/Frameworks/.Sparkle.previous.framework" ]]; then
        mv "$APP_PATH/Contents/Frameworks/.Sparkle.previous.framework" "$SPARKLE_TARGET"
    fi
    exit 1
fi
rm -rf -- "$APP_PATH/Contents/Frameworks/.Sparkle.previous.framework"
/usr/bin/codesign --verify --deep --strict "$SPARKLE_TARGET"
cp "$BUILD_ROOT/artifacts/sparkle/Sparkle/LICENSE" "$APP_PATH/Contents/Resources/Sparkle-LICENSE.txt"
if [[ "${1:-}" == "--universal" ]]; then
    /usr/bin/xcrun lipo "$SPARKLE_TARGET/Sparkle" -verify_arch arm64 x86_64
fi
for language in en ru; do
    mkdir -p "$APP_PATH/Contents/Resources/$language.lproj"
    cp "$PROJECT_ROOT/Sources/MyWallpaper/Resources/$language.lproj/Localizable.strings" \
        "$APP_PATH/Contents/Resources/$language.lproj/Localizable.strings"
    /usr/bin/plutil -lint "$APP_PATH/Contents/Resources/$language.lproj/Localizable.strings"
done

xcrun swiftc -parse-as-library -swift-version 6 \
    -module-cache-path "$BUILD_ROOT/ModuleCache" \
    "$PROJECT_ROOT/Sources/MyWallpaper/AppIconArtwork.swift" \
    "$PROJECT_ROOT/scripts/generate-icon.swift" \
    -o "$BUILD_ROOT/generate-icon"
"$BUILD_ROOT/generate-icon" "$BUILD_ROOT/MyWallpaper.iconset" \
    "$APP_PATH/Contents/Resources/AppIcon.icns" "$BUILD_ROOT/app-icon-preview1024.png"

"$PROJECT_ROOT/scripts/build-screensaver.sh" "$@"
mkdir -p "$APP_PATH/Contents/PlugIns"
SAVER_PATH="$APP_PATH/Contents/PlugIns/MyWallpaper.saver"
SAVER_STAGE="$(mktemp -d "$BUILD_ROOT/screensaver-embed.XXXXXX")"
cleanup_saver_stage() {
    local status=$?
    trap - EXIT
    if [[ ! -e "$SAVER_PATH" && -e "$SAVER_STAGE/previous.saver" ]]; then
        mv "$SAVER_STAGE/previous.saver" "$SAVER_PATH" || exit 1
    fi
    rm -rf -- "$SAVER_STAGE"
    exit "$status"
}
trap cleanup_saver_stage EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/ditto "$BUILD_ROOT/MyWallpaper.saver" "$SAVER_STAGE/MyWallpaper.saver"
/usr/bin/codesign --verify --strict "$SAVER_STAGE/MyWallpaper.saver"
if [[ -e "$SAVER_PATH" || -L "$SAVER_PATH" ]]; then
    mv "$SAVER_PATH" "$SAVER_STAGE/previous.saver"
fi
mv "$SAVER_STAGE/MyWallpaper.saver" "$SAVER_PATH"

# The nested .saver is signed first; signing the outer app seals that signature.
/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --strict "$SAVER_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"

printf '\nГотово: %s\n' "$APP_PATH"
printf 'Запуск: open "%s"\n' "$APP_PATH"
