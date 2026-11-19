#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/.build"
DIST_ROOT="$PROJECT_ROOT/dist"
APP_PATH="$DIST_ROOT/MyWallpaper.app"

usage() {
    cat <<'EOF'
Usage: ./scripts/build-dmg.sh [--skip-build]

По умолчанию собирает Universal-приложение (Apple Silicon + Intel),
затем создаёт и проверяет DMG и SHA-256 в dist/.
--skip-build  Упаковать уже собранное dist/MyWallpaper.app.
--help        Показать эту справку.
EOF
}

SKIP_BUILD=0
if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
fi
case "${1:-}" in
    "") ;;
    --skip-build) SKIP_BUILD=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    "$PROJECT_ROOT/scripts/build-app.sh" --universal
fi

PLIST_PATH="$APP_PATH/Contents/Info.plist"
if [[ ! -d "$APP_PATH" || ! -f "$PLIST_PATH" ]]; then
    printf 'Не найдено приложение: %s\n' "$APP_PATH" >&2
    exit 1
fi
/usr/bin/plutil -lint "$PLIST_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH")"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST_PATH")"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST_PATH")"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*([+-][A-Za-z0-9.-]+)?$ ]]; then
    printf 'Недопустимая версия приложения: %s\n' "$VERSION" >&2
    exit 1
fi
if [[ -z "$EXECUTABLE_NAME" || "$EXECUTABLE_NAME" == */* || "$EXECUTABLE_NAME" == "." || "$EXECUTABLE_NAME" == ".." ]]; then
    echo 'Недопустимый CFBundleExecutable.' >&2
    exit 1
fi
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
if [[ ! -x "$APP_EXECUTABLE" ]]; then
    printf 'Не найден исполняемый файл: %s\n' "$APP_EXECUTABLE" >&2
    exit 1
fi

ARCHITECTURES="$(/usr/bin/xcrun lipo -archs "$APP_EXECUTABLE")"
case "$ARCHITECTURES" in
    "arm64 x86_64"|"x86_64 arm64")
        ARCHITECTURE_SUFFIX="universal"
        ARCHITECTURE_DESCRIPTION="Universal: Apple Silicon и Intel"
        ;;
    arm64)
        ARCHITECTURE_SUFFIX="arm64"
        ARCHITECTURE_DESCRIPTION="Apple Silicon (arm64)"
        ;;
    x86_64)
        ARCHITECTURE_SUFFIX="x86_64"
        ARCHITECTURE_DESCRIPTION="Intel (x86_64)"
        ;;
    *)
        printf 'Неподдерживаемый набор архитектур: %s\n' "$ARCHITECTURES" >&2
        exit 1
        ;;
esac

DMG_NAME="MyWallpaper-$VERSION-$ARCHITECTURE_SUFFIX.dmg"
mkdir -p "$BUILD_ROOT" "$DIST_ROOT"
WORK_DIR="$(mktemp -d "$BUILD_ROOT/dmg.XXXXXX")"
PAYLOAD_PATH="$WORK_DIR/payload"
MOUNT_PATH="$WORK_DIR/mounted"
TEMP_DMG="$WORK_DIR/$DMG_NAME"
NEEDS_DETACH=0

cleanup() {
    local status=$?
    trap - EXIT
    # Never delete a directory that may still contain a mounted image.
    if [[ "$NEEDS_DETACH" -eq 1 ]]; then
        if ! /usr/bin/hdiutil detach "$MOUNT_PATH"; then
            printf 'Не удалось отключить образ. Временные файлы сохранены: %s\n' "$WORK_DIR" >&2
            exit 1
        fi
    fi
    case "$WORK_DIR" in
        "$BUILD_ROOT"/dmg.*) rm -rf -- "$WORK_DIR" ;;
        *) printf 'Неожиданный путь временных файлов: %s\n' "$WORK_DIR" >&2; exit 1 ;;
    esac
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$PAYLOAD_PATH" "$MOUNT_PATH"
/usr/bin/ditto "$APP_PATH" "$PAYLOAD_PATH/MyWallpaper.app"
ln -s /Applications "$PAYLOAD_PATH/Applications"
cat > "$PAYLOAD_PATH/INSTALL.txt" <<EOF
MyWallpaper $VERSION
macOS $MINIMUM_MACOS и новее · $ARCHITECTURE_DESCRIPTION

Установка
1. Завершите предыдущую версию MyWallpaper, если она запущена.
2. Перетащите MyWallpaper.app в Applications («Программы»).
3. Откройте MyWallpaper из папки «Программы» и выберите MP4 или MOV.
4. Извлеките этот образ диска после установки.

После закрытия окна приложение остаётся в строке меню.
Автозапуск настраивается в разделе «Основные».

Первый запуск
Эта сборка подписана локально (ad-hoc) и не прошла нотарификацию Apple.
Если macOS не может проверить разработчика или приложение, попробуйте открыть его,
затем перейдите в «Системные настройки» → «Конфиденциальность и безопасность»
и нажмите «Все равно открыть» (Open Anyway), если доверяете источнику загрузки.
Инструкция Apple: https://support.apple.com/ru-ru/102445
EOF
/usr/bin/codesign --verify --deep --strict "$PAYLOAD_PATH/MyWallpaper.app"

/usr/bin/hdiutil create \
    -srcfolder "$PAYLOAD_PATH" \
    -volname "MyWallpaper $VERSION" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -nospotlight \
    -anyowners \
    "$TEMP_DMG"
/usr/bin/hdiutil verify "$TEMP_DMG"
if [[ "$(/usr/bin/hdiutil imageinfo -format "$TEMP_DMG")" != "UDZO" ]]; then
    echo 'Созданный образ имеет неожиданный формат.' >&2
    exit 1
fi

# Inspect the final read-only filesystem without opening Finder or the app.
# Set this before attach so a partial failure cannot lead to deleting a mount.
NEEDS_DETACH=1
/usr/bin/hdiutil attach "$TEMP_DMG" \
    -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_PATH"
/usr/bin/codesign --verify --deep --strict "$MOUNT_PATH/MyWallpaper.app"
cmp "$APP_EXECUTABLE" "$MOUNT_PATH/MyWallpaper.app/Contents/MacOS/$EXECUTABLE_NAME"
cmp "$PAYLOAD_PATH/INSTALL.txt" "$MOUNT_PATH/INSTALL.txt"
if [[ ! -L "$MOUNT_PATH/Applications" || "$(readlink "$MOUNT_PATH/Applications")" != "/Applications" ]]; then
    echo 'В образе отсутствует корректная ссылка на Applications.' >&2
    exit 1
fi
/usr/bin/hdiutil detach "$MOUNT_PATH"
NEEDS_DETACH=0

(
    cd "$WORK_DIR"
    /usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
    /usr/bin/shasum -a 256 -c "$DMG_NAME.sha256"
)
mv -f "$TEMP_DMG" "$DIST_ROOT/$DMG_NAME"
mv -f "$WORK_DIR/$DMG_NAME.sha256" "$DIST_ROOT/$DMG_NAME.sha256"

printf '\nГотово: %s\n' "$DIST_ROOT/$DMG_NAME"
printf 'SHA-256: %s\n' "$DIST_ROOT/$DMG_NAME.sha256"
