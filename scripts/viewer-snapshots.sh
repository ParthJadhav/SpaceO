#!/usr/bin/env bash
# Screenshot every Viewer preview scenario, each inside its own SpaceO session, so a Viewer
# change can be reviewed screen by screen without touching the desktop or any real session.
#
#   scripts/viewer-snapshots.sh [--out DIR] [--app PATH] [--skip-build] [scenario ...]
#
# Previews run on fixtures (`SpaceO Viewer --preview NAME`, see ViewerPreview.swift): no daemon
# requests, no display capture, and Control is never taken. The app is launched with
# `--background`, which never activates it, so the person's frontmost app and Space stay put.
# Needs a running SpaceO daemon that can capture (`spaceo doctor`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPACEO="${SPACEO:-spaceo}"
OUT="${TMPDIR:-/tmp}/spaceo-viewer-snapshots"
APP=""
BUILD=1
SCENARIOS=()

fail() { echo "error: $*" >&2; exit 1; }

while (( $# )); do
    case "$1" in
        --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
        --app) APP="${2:?--app needs a .app path}"; BUILD=0; shift 2 ;;
        --skip-build) BUILD=0; shift ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        -*) fail "unknown option $1" ;;
        *) SCENARIOS+=("$1"); shift ;;
    esac
done

command -v "$SPACEO" >/dev/null 2>&1 || fail "spaceo is not on PATH (set SPACEO=/path/to/spaceo)"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to read window geometry"
"$SPACEO" daemon wait --timeout 5 >/dev/null 2>&1 || fail "no SpaceO daemon is answering"

# A copy under its own bundle id, so it never collides with an installed Viewer.
STAGING="${TMPDIR:-/tmp}/spaceo-viewer-preview"
if [[ -z "$APP" ]]; then
    APP="$STAGING/SpaceO Viewer Preview.app"
    if (( BUILD )); then
        (cd "$REPOSITORY_ROOT" && swift build -c release --product SpaceOViewer >/dev/null)
        (cd "$REPOSITORY_ROOT" && swift build -c release --product spaceo >/dev/null)
        mkdir -p "$STAGING"
        SPACEO_CODESIGN_IDENTITY=- bash "$SCRIPT_DIR/make-viewer-app.sh" \
            "$REPOSITORY_ROOT/.build/release/SpaceOViewer" "$APP" >/dev/null
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.spaceo.viewer.preview" \
            -c "Set :CFBundleName SpaceO Viewer Preview" "$APP/Contents/Info.plist"
        codesign --force --deep --sign - "$APP" >/dev/null 2>&1
    fi
fi
[[ -x "$APP/Contents/MacOS/SpaceOViewer" ]] || fail "no Viewer build at $APP (drop --skip-build)"

if (( ${#SCENARIOS[@]} == 0 )); then
    while IFS= read -r name; do SCENARIOS+=("$name"); done \
        < <("$APP/Contents/MacOS/SpaceOViewer" --list-previews)
fi
mkdir -p "$OUT"

cleanup() {
    if [[ -n "${SPACEO_SESSION:-}" ]]; then
        "$SPACEO" session destroy >/dev/null 2>&1 || true
        unset SPACEO_SESSION SPACEO_LEASE
    fi
}
trap cleanup EXIT INT TERM

for scenario in "${SCENARIOS[@]}"; do
    eval "$("$SPACEO" session create --export \
        --title "Viewer preview: $scenario")"
    "$SPACEO" run "$APP" --new-instance --timeout 20 \
        --arguments-json "[\"--background\",\"--preview\",\"$scenario\"]" >/dev/null
    # Fixtures land on the first poll; scenario staging runs 1.2 s after the window appears.
    # Offline is declared five seconds after the first failed poll.
    if [[ "$scenario" == offline ]]; then sleep 7; else sleep 3; fi
    # The window's own frame, captured as a region so sheets over it are included. Region
    # coordinates are measured from the session's area, not the window.
    region="$(python3 - "$SPACEO_SESSION" \
        "$("$SPACEO" session list --json)" "$("$SPACEO" windows --json)" <<'PY'
import json, sys
session_id, sessions, windows = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3])
area = next(s for s in sessions.get("sessions") or [] if s.get("id") == session_id)
main = max(windows.get("windows") or [], key=lambda w: w["width"] * w["height"])
print(int(main["x"] - area["x"]), int(main["y"] - area["y"]),
      int(main["width"]), int(main["height"]))
PY
)"
    read -r x y width height <<<"$region"
    "$SPACEO" screenshot --x "$x" --y "$y" --width "$width" --height "$height" \
        -o "$OUT/$scenario.png" >/dev/null
    echo "$OUT/$scenario.png"
    cleanup
done
