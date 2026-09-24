#!/usr/bin/env bash
# Local signing only; this does not notarize, install, launch, or publish anything.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT/.build/signed"
IDENTITY="${SPACEO_CODESIGN_IDENTITY:-}"
fail() { echo "error: $*" >&2; exit 1; }

if [[ -z "$IDENTITY" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application:/ { print $2 }')"
    [[ -n "$IDENTITIES" && "$IDENTITIES" != *$'\n'* ]] \
        || fail "Select one installed Developer ID Application certificate with SPACEO_CODESIGN_IDENTITY."
    IDENTITY="$IDENTITIES"
fi
[[ "$IDENTITY" == "Developer ID Application:"* ]] \
    || fail "A Developer ID Application certificate is required; ad-hoc signing is not supported."

mkdir -p "$OUTPUT"
STAGED="$(mktemp "$OUTPUT/.spaceo.XXXXXX")"
trap 'rm -f "$STAGED"' EXIT
cp "$ROOT/.build/release/spaceo" "$STAGED"
chmod 755 "$STAGED"
codesign --force --identifier dev.spaceo.cli --options runtime --timestamp \
    --sign "$IDENTITY" "$STAGED"
codesign --verify --strict "$STAGED"

# Do not silently switch identities and invalidate grants on an existing signed CLI.
if [[ -f "$OUTPUT/spaceo" ]]; then
    REQUIREMENT="$(codesign -d -r- "$OUTPUT/spaceo" 2>&1 | sed -n 's/^designated => //p')"
    [[ -n "$REQUIREMENT" ]] || fail "Existing signed CLI has no readable identity."
    codesign --verify --strict -R "=$REQUIREMENT" "$STAGED" \
        || fail "Signing identity changed; existing signed artifacts were preserved."
fi

SPACEO_CODESIGN_IDENTITY="$IDENTITY" bash "$ROOT/scripts/make-viewer-app.sh" \
    "$ROOT/.build/release/SpaceOViewer" "$OUTPUT/SpaceO Viewer.app"
mv -f "$STAGED" "$OUTPUT/spaceo"
echo "Signed local CLI: $OUTPUT/spaceo"
echo "Signed local Viewer: $OUTPUT/SpaceO Viewer.app"
echo "Use these same paths after each make signed. Initial macOS permission grants are still required."
