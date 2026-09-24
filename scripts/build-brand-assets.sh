#!/usr/bin/env bash
# Render the canonical brand mark into the ICNS file shipped by SpaceO Viewer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$REPOSITORY_ROOT/Assets/Brand/spaceo-logo.png"
OUTPUT="$REPOSITORY_ROOT/Assets/Brand/SpaceO.icns"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spaceo-brand.XXXXXX")"
ICONSET="$WORK_DIR/SpaceO.iconset"
MASTER="$WORK_DIR/SpaceO-master.png"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

[[ -f "$SOURCE" ]] || { echo "error: missing app-icon source at $SOURCE" >&2; exit 1; }
mkdir -p "$ICONSET"
sips -z 1024 1024 "$SOURCE" --out "$MASTER" >/dev/null

render_size() {
    local pixels="$1"
    local filename="$2"
    sips -z "$pixels" "$pixels" "$MASTER" --out "$ICONSET/$filename" >/dev/null
}

render_size 16 icon_16x16.png
render_size 32 icon_16x16@2x.png
render_size 32 icon_32x32.png
render_size 64 icon_32x32@2x.png
render_size 128 icon_128x128.png
render_size 256 icon_128x128@2x.png
render_size 256 icon_256x256.png
render_size 512 icon_256x256@2x.png
render_size 512 icon_512x512.png
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "built $OUTPUT"
