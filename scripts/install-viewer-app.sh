#!/usr/bin/env bash
# Build, sign, install, and open the SpaceO Viewer app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="SpaceO Viewer.app"
BUILT_APP="$REPOSITORY_ROOT/.build/$APP_NAME"
APPLICATIONS_DIR="${SPACEO_APPLICATIONS_DIR:-/Applications}"
INSTALLED_APP="$APPLICATIONS_DIR/$APP_NAME"
OPEN_AFTER_INSTALL=1
STAGING_ROOT=""
BACKUP_APP=""
INSTALL_COMMITTED=0

fail() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
usage: scripts/install-viewer-app.sh [--no-open]

Builds and signs SpaceO Viewer, installs it in /Applications, verifies the installed
signature, and opens the app. Set SPACEO_APPLICATIONS_DIR to choose another Applications
directory. Set SPACEO_CODESIGN_IDENTITY to select the signing identity used by the build.
USAGE
}

cleanup() {
    local status=$?
    local preserve_staging=0
    set +e
    # Until the newly installed bundle passes its final verification, the previous app is the
    # committed version. A signal between the two `mv` calls must restore it before removing the
    # staging directory that currently holds the only backup.
    if (( ! INSTALL_COMMITTED )) && [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
        if [[ -e "$INSTALLED_APP" || -L "$INSTALLED_APP" ]]; then
            rm -rf "$INSTALLED_APP"
        fi
        if ! mv "$BACKUP_APP" "$INSTALLED_APP"; then
            preserve_staging=1
            echo "warning: could not restore the previous app at $INSTALLED_APP; " \
                 "the backup remains at $BACKUP_APP" >&2
        fi
    fi
    if (( ! preserve_staging )) && [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
        rm -rf "$STAGING_ROOT"
    fi
    exit "$status"
}
trap cleanup EXIT

case "${1:-}" in
    "") ;;
    --no-open) OPEN_AFTER_INSTALL=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
esac
(( $# <= 1 )) || { usage >&2; fail "too many arguments"; }

[[ "$(uname -s)" == "Darwin" ]] || fail "SpaceO Viewer installation requires macOS"
command -v codesign >/dev/null 2>&1 || fail "required command is unavailable: codesign"
command -v ditto >/dev/null 2>&1 || fail "required command is unavailable: ditto"
command -v make >/dev/null 2>&1 || fail "required command is unavailable: make"
if (( OPEN_AFTER_INSTALL )); then
    command -v open >/dev/null 2>&1 || fail "required command is unavailable: open"
fi

[[ "$APPLICATIONS_DIR" == /* && "$APPLICATIONS_DIR" != "/" ]] \
    || fail "SPACEO_APPLICATIONS_DIR must be an absolute directory other than /"
if [[ ! -d "$APPLICATIONS_DIR" ]]; then
    mkdir -p "$APPLICATIONS_DIR" \
        || fail "cannot create Applications directory: $APPLICATIONS_DIR"
fi
[[ -w "$APPLICATIONS_DIR" ]] \
    || fail "$APPLICATIONS_DIR is not writable; install as an administrator or set SPACEO_APPLICATIONS_DIR"

make -C "$REPOSITORY_ROOT" viewer
[[ -d "$BUILT_APP" ]] || fail "Viewer build did not produce $BUILT_APP"
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

# Copy into a sibling staging directory so the final move stays on the Applications volume.
# Preserve the old app until the staged bundle's signature has also passed verification.
STAGING_ROOT="$(mktemp -d "$APPLICATIONS_DIR/.spaceo-install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/$APP_NAME"
ditto "$BUILT_APP" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

if [[ -e "$INSTALLED_APP" || -L "$INSTALLED_APP" ]]; then
    BACKUP_APP="$STAGING_ROOT/previous-$APP_NAME"
    mv "$INSTALLED_APP" "$BACKUP_APP"
fi

if ! mv "$STAGED_APP" "$INSTALLED_APP"; then
    if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
        mv "$BACKUP_APP" "$INSTALLED_APP"
    fi
    fail "could not install $INSTALLED_APP"
fi

if ! codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"; then
    rm -rf "$INSTALLED_APP"
    if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
        mv "$BACKUP_APP" "$INSTALLED_APP"
    fi
    fail "installed app failed signature verification; the previous app was restored"
fi

# From here on, cleanup may discard the backup: the replacement is installed and verified.
INSTALL_COMMITTED=1
if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
    rm -rf "$BACKUP_APP"
fi

if (( OPEN_AFTER_INSTALL )); then
    open "$INSTALLED_APP"
    echo "installed, verified, and opened $INSTALLED_APP"
else
    echo "installed and verified $INSTALLED_APP"
fi
