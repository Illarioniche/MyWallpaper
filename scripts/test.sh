#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/.build"

mkdir -p "$BUILD_ROOT/ModuleCache" "$BUILD_ROOT/cache" "$BUILD_ROOT/config" "$BUILD_ROOT/security"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/ModuleCache"

# Some Command Line Tools releases bundle Swift Testing but SwiftPM does not
# automatically add its framework, macro plugin and runtime search paths.
DEVELOPER_ROOT="$(xcode-select -p)"
SWIFTC_PATH="$(xcrun --find swiftc)"
TOOLCHAIN_USR="$(cd -- "$(dirname -- "$SWIFTC_PATH")/.." && pwd)"
TESTING_OPTIONS=(--disable-xctest --enable-swift-testing)
for framework_root in \
    "$DEVELOPER_ROOT/Library/Developer/Frameworks" \
    "$DEVELOPER_ROOT/Platforms/MacOSX.platform/Developer/Library/Frameworks"; do
    if [ -d "$framework_root/Testing.framework" ]; then
        TESTING_OPTIONS+=(
            -Xswiftc -F -Xswiftc "$framework_root"
            -Xlinker -F -Xlinker "$framework_root"
            -Xlinker -rpath -Xlinker "$framework_root"
        )
        for runtime_root in "$framework_root/../usr/lib" "$framework_root/../../usr/lib"; do
            if [ -f "$runtime_root/lib_TestingInterop.dylib" ]; then
                TESTING_OPTIONS+=(-Xlinker -rpath -Xlinker "$runtime_root")
            fi
        done
        break
    fi
done

TESTING_PLUGIN="$TOOLCHAIN_USR/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$TESTING_PLUGIN" ]; then
    TESTING_OPTIONS+=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
fi

xcrun swift test \
    --package-path "$PROJECT_ROOT" \
    --scratch-path "$BUILD_ROOT" \
    --cache-path "$BUILD_ROOT/cache" \
    --config-path "$BUILD_ROOT/config" \
    --security-path "$BUILD_ROOT/security" \
    --disable-keychain --disable-netrc \
    --disable-sandbox \
    "${TESTING_OPTIONS[@]}" \
    "$@"
