#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -ne 0 ]]; then
    echo "Usage: $0 (creates/reuses the MyWallpaper update key in macOS Keychain)" >&2
    exit 2
fi
TOOLS_BIN="$("$PROJECT_ROOT/scripts/sparkle-tools.sh")"
ACCOUNT=local.mywallpaper.MyWallpaper
# generate_keys only creates a key when this account does not have one. It never
# exports private material. Only the public key goes into the application.
"$TOOLS_BIN/generate_keys" --account "$ACCOUNT"
PUBLIC_KEY="$("$TOOLS_BIN/generate_keys" --account "$ACCOUNT" -p)"
python3 - "$PROJECT_ROOT/Resources/Info.plist" "$PUBLIC_KEY" <<'PY'
import base64, pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
key = sys.argv[2].strip()
if len(base64.b64decode(key, validate=True)) != 32:
    raise SystemExit("Invalid Sparkle public key.")
info = plistlib.loads(path.read_bytes())
existing = info.get("SUPublicEDKey")
if existing and existing != key:
    raise SystemExit("The existing public key does not match this Keychain. Restore the original key; do not silently rotate it.")
if existing != key:
    # Keep the hand-maintained plist formatting.
    text = path.read_text()
    path.write_text(text.replace("</dict>", "    <key>SUPublicEDKey</key>\n    <string>" + key + "</string>\n</dict>"))
print("Update signing is configured. The private key stays in macOS Keychain.")
PY
