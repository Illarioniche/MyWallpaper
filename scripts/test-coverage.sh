#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/.build/coverage"

if [[ $# -ne 1 || ( "$1" != "--build-only" && "$1" != "--run" ) ]]; then
    echo "Usage: $0 --build-only | --run" >&2
    echo "--run temporarily opens small, noninteractive test windows for at most 14 seconds." >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR" "$PROJECT_ROOT/.build/ModuleCache"
xcrun swiftc -parse-as-library -swift-version 6 \
    -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
    "$PROJECT_ROOT/Sources/MyWallpaper/DesktopCoverageMonitor.swift" \
    "$PROJECT_ROOT/Tests/Integration/CoverageSmokeTest.swift" \
    -o "$OUTPUT_DIR/coverage-smoke-test"

if [[ "$1" == "--build-only" ]]; then
    echo "Built $OUTPUT_DIR/coverage-smoke-test"
    exit 0
fi

exec "$OUTPUT_DIR/coverage-smoke-test" --run
