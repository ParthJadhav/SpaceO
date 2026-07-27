#!/usr/bin/env bash
# Wrap the built SpaceOViewer binary in a minimal .app bundle.
#
# A bundle with a stable identifier and certificate-backed signature gives the viewer a
# consistent TCC identity, so Screen Recording and Accessibility grants survive rebuilds.
# SPACEO_CODESIGN_IDENTITY may select a specific identity (or "-" for ad-hoc signing).
set -euo pipefail

BIN="${1:?usage: make-viewer-app.sh <built-binary> <output.app>}"
APP="${2:?usage: make-viewer-app.sh <built-binary> <output.app>}"

[ -x "$BIN" ] || { echo "error: $BIN is not an executable" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SpaceOViewer"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

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

codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP"
echo "built $APP (signed with $SIGNING_IDENTITY)"
