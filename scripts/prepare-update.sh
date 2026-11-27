#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--skip-build" ) ]]; then
    echo "Usage: $0 [--skip-build] (creates DMG, SHA-256 and signed appcast.xml; does not publish)" >&2
    exit 2
fi
TOOLS_BIN="$("$PROJECT_ROOT/scripts/sparkle-tools.sh")"
"$PROJECT_ROOT/scripts/build-dmg.sh" "$@"
exec python3 "$PROJECT_ROOT/scripts/prepare-appcast.py" \
    --app "$PROJECT_ROOT/dist/MyWallpaper.app" \
    --dist "$PROJECT_ROOT/dist" --sparkle-bin "$TOOLS_BIN"
