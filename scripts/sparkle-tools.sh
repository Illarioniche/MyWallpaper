#!/bin/bash
set -euo pipefail

# Pin the tools to the framework version. The checksum is the official release
# asset's SHA-256; never execute a downloaded archive before checking it.
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
TOOLS_ROOT="$PROJECT_ROOT/.build/sparkle-tools/$VERSION"
ARCHIVE="$PROJECT_ROOT/.build/Sparkle-$VERSION.tar.xz"
if [[ $# -ne 0 ]]; then
    echo "Usage: $0 (prints the verified Sparkle tools directory)" >&2
    exit 2
fi
mkdir -p "$PROJECT_ROOT/.build/sparkle-tools"
if [[ ! -f "$ARCHIVE" ]] || [[ "$(/usr/bin/shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)" != "$SHA256" ]]; then
    /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
        -o "$ARCHIVE.download"
    [[ "$(/usr/bin/shasum -a 256 "$ARCHIVE.download" | cut -d ' ' -f 1)" == "$SHA256" ]] || {
        echo 'Sparkle tools checksum mismatch.' >&2; rm -f "$ARCHIVE.download"; exit 1;
    }
    mv -f "$ARCHIVE.download" "$ARCHIVE"
fi
# Re-extract from the verified archive, so an old/tampered tool cache is not used.
STAGE="$(mktemp -d "$PROJECT_ROOT/.build/sparkle-tools/stage.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
/usr/bin/tar -xJf "$ARCHIVE" -C "$STAGE"
for executable in generate_keys sign_update generate_appcast; do
    /usr/bin/codesign --verify --strict "$STAGE/bin/$executable"
done
rm -rf -- "$TOOLS_ROOT"
mv "$STAGE" "$TOOLS_ROOT"
printf '%s\n' "$TOOLS_ROOT/bin"
