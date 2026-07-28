#!/usr/bin/env bash
# Wrap the built SpaceOViewer binary in a minimal .app bundle.
#
# A bundle with a stable identifier and certificate-backed signature gives the viewer a
# consistent TCC identity, so Screen Recording and Accessibility grants survive rebuilds.
# SPACEO_CODESIGN_IDENTITY may select a specific identity (or "-" for an ad-hoc development
# build). SPACEO_DISTRIBUTION=1 refuses ad-hoc and non-Developer-ID identities.
set -euo pipefail

BIN="${1:?usage: make-viewer-app.sh <built-binary> <output.app>}"
APP="${2:?usage: make-viewer-app.sh <built-binary> <output.app>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${SPACEO_VERSION:-$(tr -d '[:space:]' < "$REPOSITORY_ROOT/VERSION")}"
DISTRIBUTION="${SPACEO_DISTRIBUTION:-0}"

[ -x "$BIN" ] || { echo "error: $BIN is not an executable" >&2; exit 1; }
[[ "$APP" == *.app && "$APP" != "/" ]] || {
    echo "error: Viewer output must be an explicit .app path" >&2
    exit 1
}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: SpaceO version must be numeric MAJOR.MINOR.PATCH, got: $VERSION" >&2
    exit 1
}
if [[ "$DISTRIBUTION" == "1" && -z "${SPACEO_CODESIGN_IDENTITY:-}" ]]; then
    echo "error: distributable Viewer builds require an explicit signing identity" >&2
    exit 1
fi

SIGNING_IDENTITY="${SPACEO_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Developer ID Application:/ { print $2; exit }'
    )"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Apple Development:/ { print $2; exit }'
    )"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
    echo "warning: no certificate-backed signing identity found; privacy grants may need" \
         "to be refreshed after each rebuild" >&2
fi
if [[ "$DISTRIBUTION" == "1" && "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "error: distributable Viewer builds require an explicit Developer ID Application identity" >&2
    exit 1
fi
if [[ "$DISTRIBUTION" == "1" ]] && ! security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "\"$SIGNING_IDENTITY\"" >/dev/null; then
    echo "error: the requested Developer ID Application identity is not installed" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SpaceOViewer"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>SpaceO Viewer</string>
    <key>CFBundleDisplayName</key>     <string>SpaceO Viewer</string>
    <key>CFBundleIdentifier</key>      <string>dev.spaceo.viewer</string>
    <key>CFBundleExecutable</key>      <string>SpaceOViewer</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "built $APP version $VERSION (signed with $SIGNING_IDENTITY)"
