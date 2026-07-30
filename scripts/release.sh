#!/usr/bin/env bash
# Build, sign, notarize, staple, and verify the public SpaceO macOS distribution.
#
# Publication is deliberately credential-gated. Supply SPACEO_CODESIGN_IDENTITY plus either:
#   - SPACEO_NOTARY_PROFILE (an existing keychain profile chosen by the releaser), or
#   - SPACEO_NOTARY_KEY, SPACEO_NOTARY_KEY_ID, and SPACEO_NOTARY_ISSUER.
#
# This script never creates a keychain profile and never prints credential values.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPOSITORY_ROOT/VERSION"
VERSION_SOURCE="$REPOSITORY_ROOT/Sources/SpaceOKit/SpaceOVersion.swift"
PUBLISHER_TEAM_ID="75LRT8TRQY"
CLI_IDENTIFIER="dev.spaceo.cli"
VIEWER_IDENTIFIER="dev.spaceo.viewer"
CHECKSUM_IDENTIFIER="dev.spaceo.release-checksum"
SWIFT="${SWIFT:-swift}"
NODE="${NODE:-node}"
RELEASE_ROOT="${SPACEO_RELEASE_DIR:-$REPOSITORY_ROOT/.release}"
SIGNING_IDENTITY="${SPACEO_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${SPACEO_NOTARY_PROFILE:-}"
NOTARY_KEY="${SPACEO_NOTARY_KEY:-}"
NOTARY_KEY_ID="${SPACEO_NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${SPACEO_NOTARY_ISSUER:-}"
NOTARY_ARGS=()
ACTIVE_MOUNT=""
WORK_DIR=""

fail() {
    echo "error: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$ACTIVE_MOUNT" && -d "$ACTIVE_MOUNT" ]]; then
        hdiutil detach "$ACTIVE_MOUNT" -quiet >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'USAGE'
usage: scripts/release.sh COMMAND [artifact.dmg]

Commands:
  check       Validate version consistency and required local tooling.
  dry-run     Show the versioned release plan and credential blockers; mutate nothing.
  preflight   Validate the Developer ID identity and deliberate notary credentials.
  package     Build, test, sign, notarize, staple, and verify the release DMG.
  verify      Authenticate and re-run checksum, staple, Gatekeeper, and version checks.

`package` and `preflight` fail closed unless SPACEO_CODESIGN_IDENTITY is an installed
SpaceO publisher identity and one supported notary credential set is supplied. `verify`
requires the adjacent publisher-signed .sha256 and .sha256.sig files.
USAGE
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

load_version() {
    [[ -f "$VERSION_FILE" ]] || fail "missing VERSION file"
    VERSION="$(tr -d '\r\n' < "$VERSION_FILE")"
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail "VERSION must contain numeric MAJOR.MINOR.PATCH, got: $VERSION"

    local source_version
    source_version="$(
        awk -F'"' '/public static let current =/ { print $2; exit }' "$VERSION_SOURCE"
    )"
    [[ "$source_version" == "$VERSION" ]] \
        || fail "VERSION ($VERSION) does not match SpaceOVersion.current ($source_version)"
    grep -F "SpaceOVersion.current" "$REPOSITORY_ROOT/Sources/spaceo/main.swift" >/dev/null \
        || fail "CLI version output must use SpaceOVersion.current"
    grep -F "SpaceOVersion.current" "$REPOSITORY_ROOT/Sources/SpaceOMCP/MCPServer.swift" >/dev/null \
        || fail "MCP version output must use SpaceOVersion.current"

    if [[ -n "${SPACEO_RELEASE_TAG:-}" ]]; then
        [[ "$SPACEO_RELEASE_TAG" == "v$VERSION" ]] \
            || fail "release tag $SPACEO_RELEASE_TAG does not match VERSION v$VERSION"
    fi
}

release_architecture() {
    case "$(uname -m)" in
        arm64) echo "arm64" ;;
        *) fail "SpaceO releases require Apple Silicon (arm64), got: $(uname -m)" ;;
    esac
}

check_common() {
    load_version
    require_command "$SWIFT"
    require_command "$NODE"
    require_command security
    require_command codesign
    require_command spctl
    require_command hdiutil
    require_command ditto
    require_command plutil
    require_command shasum
    require_command xcrun
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
    release_architecture >/dev/null
}

configure_signing() {
    [[ -n "$SIGNING_IDENTITY" ]] \
        || fail "SPACEO_CODESIGN_IDENTITY must explicitly name the Developer ID identity"
    [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]] \
        || fail "SPACEO_CODESIGN_IDENTITY must be a Developer ID Application identity"
    [[ "$SIGNING_IDENTITY" =~ \("$PUBLISHER_TEAM_ID"\)$ ]] \
        || fail "SPACEO_CODESIGN_IDENTITY must belong to SpaceO publisher team $PUBLISHER_TEAM_ID"
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -F "\"$SIGNING_IDENTITY\"" >/dev/null \
        || fail "the requested Developer ID Application identity is not installed"
}

configure_notary() {
    local api_count=0
    [[ -n "$NOTARY_KEY" ]] && api_count=$((api_count + 1))
    [[ -n "$NOTARY_KEY_ID" ]] && api_count=$((api_count + 1))
    [[ -n "$NOTARY_ISSUER" ]] && api_count=$((api_count + 1))

    if [[ -n "$NOTARY_PROFILE" ]]; then
        [[ "$api_count" -eq 0 ]] \
            || fail "choose either SPACEO_NOTARY_PROFILE or API-key inputs, not both"
        NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
        NOTARY_MODE="explicit keychain profile"
        return
    fi

    if [[ "$api_count" -ne 0 ]]; then
        [[ "$api_count" -eq 3 ]] \
            || fail "API notarization requires SPACEO_NOTARY_KEY, _KEY_ID, and _ISSUER together"
        [[ -r "$NOTARY_KEY" ]] || fail "SPACEO_NOTARY_KEY is not a readable file"
        NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
        NOTARY_MODE="explicit App Store Connect API key"
        return
    fi

    fail "notarization credentials are absent; set an existing SPACEO_NOTARY_PROFILE or all three SPACEO_NOTARY_KEY inputs"
}

credential_summary() {
    if [[ -n "$NOTARY_PROFILE" ]]; then
        echo "notarization input : explicit keychain profile supplied"
    elif [[ -n "$NOTARY_KEY" || -n "$NOTARY_KEY_ID" || -n "$NOTARY_ISSUER" ]]; then
        echo "notarization input : App Store Connect API inputs supplied"
    else
        echo "notarization input : MISSING (publication will fail closed)"
    fi
}

run_preflight() {
    check_common
    configure_signing
    configure_notary
    xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null
    echo "release preflight passed for SpaceO $VERSION"
    echo "signing identity   : $SIGNING_IDENTITY"
    echo "notarization input : $NOTARY_MODE"
}

notarize() {
    local artifact="$1"
    local label="$2"
    local result_file="$WORK_DIR/notary-$label.json"
    local status

    if ! xcrun notarytool submit "$artifact" \
        "${NOTARY_ARGS[@]}" \
        --wait \
        --output-format json > "$result_file"; then
        fail "notary submission failed for $label"
    fi
    status="$(plutil -extract status raw -o - "$result_file" 2>/dev/null || true)"
    [[ "$status" == "Accepted" ]] \
        || fail "notary service did not accept $label (status: ${status:-unknown})"
    echo "notary service accepted $label"
}

assert_embedded_versions() {
    local cli="$1"
    local app="$2"
    local cli_json
    local app_version
    local app_build

    cli_json="$("$cli" version --json)"
    [[ "$cli_json" == "{\"version\":\"$VERSION\"}" ]] \
        || fail "CLI reports an unexpected version: $cli_json"
    app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
    app_build="$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")"
    [[ "$app_version" == "$VERSION" && "$app_build" == "$VERSION" ]] \
        || fail "Viewer bundle version does not match VERSION"
}

publisher_requirement() {
    local identifier="$1"
    printf '=anchor apple generic and certificate leaf[subject.OU] = "%s" and identifier "%s"' \
        "$PUBLISHER_TEAM_ID" "$identifier"
}

assert_publisher_signature() {
    local executable="$1"
    local expected_identifier="$2"
    local verify_deep="${3:-false}"
    local requirement
    local details
    local verify_arguments=(--verify --strict --verbose=2)
    requirement="$(publisher_requirement "$expected_identifier")"
    if [[ "$verify_deep" == true ]]; then
        verify_arguments+=(--deep)
    fi
    verify_arguments+=(-R "$requirement")
    codesign "${verify_arguments[@]}" "$executable"

    details="$(codesign --display --verbose=4 "$executable" 2>&1)"
    grep -F "Identifier=$expected_identifier" <<<"$details" >/dev/null \
        || fail "artifact has an unexpected signing identifier: $executable"
    grep -F "Authority=Developer ID Application:" <<<"$details" >/dev/null \
        || fail "artifact is not signed by a Developer ID Application identity: $executable"
    grep -F "Timestamp=" <<<"$details" >/dev/null \
        || fail "artifact signature has no secure timestamp: $executable"
    grep -F "TeamIdentifier=$PUBLISHER_TEAM_ID" <<<"$details" >/dev/null \
        || fail "artifact is not signed by SpaceO publisher team $PUBLISHER_TEAM_ID: $executable"
    grep -E '^CodeDirectory .*flags=.*\(runtime\)' <<<"$details" >/dev/null \
        || fail "artifact signature does not enable the hardened runtime: $executable"
}

assert_checksum_signature() {
    local checksum="$1"
    local signature="$2"
    local details
    codesign \
        --verify \
        --detached "$signature" \
        --strict \
        --verbose=2 \
        -R "$(publisher_requirement "$CHECKSUM_IDENTIFIER")" \
        "$checksum"
    details="$(codesign --display --detached "$signature" --verbose=4 "$checksum" 2>&1)"
    grep -F "Identifier=$CHECKSUM_IDENTIFIER" <<<"$details" >/dev/null \
        || fail "checksum signature has an unexpected identifier"
    grep -F "Authority=Developer ID Application:" <<<"$details" >/dev/null \
        || fail "checksum is not signed by a Developer ID Application identity"
    grep -F "Timestamp=" <<<"$details" >/dev/null \
        || fail "checksum signature has no secure timestamp"
    grep -F "TeamIdentifier=$PUBLISHER_TEAM_ID" <<<"$details" >/dev/null \
        || fail "checksum is not signed by SpaceO publisher team $PUBLISHER_TEAM_ID"
}

verify_checksum_contents() {
    local artifact="$1"
    local checksum="$2"
    local line_count
    local recorded_digest
    local recorded_name
    local unexpected
    local actual_digest
    line_count="$(awk 'END { print NR }' "$checksum")"
    [[ "$line_count" == 1 ]] || fail "checksum sidecar must contain exactly one entry"
    read -r recorded_digest recorded_name unexpected < "$checksum"
    [[ "$recorded_digest" =~ ^[0-9a-f]{64}$ && -z "$unexpected" ]] \
        || fail "checksum sidecar has an invalid SHA-256 entry"
    [[ "$recorded_name" == "$(basename "$artifact")" ]] \
        || fail "checksum sidecar does not name $(basename "$artifact")"
    actual_digest="$(shasum -a 256 "$artifact" | awk '{ print $1 }')"
    [[ "$actual_digest" == "$recorded_digest" ]] \
        || fail "release artifact does not match its authenticated checksum"
}

verify_distribution() {
    local artifact="$1"
    local checksum="${artifact%.dmg}.sha256"
    local checksum_signature="$checksum.sig"
    local mount_point
    local cli
    local app

    [[ "$artifact" == *.dmg ]] || fail "release artifact must be a .dmg: $artifact"
    [[ -f "$artifact" ]] || fail "release artifact does not exist: $artifact"
    [[ -f "$checksum" ]] || fail "checksum sidecar does not exist: $checksum"
    [[ -f "$checksum_signature" ]] \
        || fail "publisher signature does not exist: $checksum_signature"

    # Authenticate the checksum before allowing its attacker-controlled filename and digest to
    # participate in verification. The mounted payload is independently pinned below.
    assert_checksum_signature "$checksum" "$checksum_signature"
    verify_checksum_contents "$artifact" "$checksum"
    xcrun stapler validate "$artifact"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$artifact"

    mount_point="$(mktemp -d "${TMPDIR:-/tmp}/spaceo-verify.XXXXXX")"
    ACTIVE_MOUNT="$mount_point"
    hdiutil attach "$artifact" -readonly -nobrowse -mountpoint "$mount_point" -quiet
    cli="$mount_point/spaceo"
    app="$mount_point/SpaceO Viewer.app"
    [[ -x "$cli" ]] || fail "DMG is missing its CLI executable"
    [[ -d "$app" ]] || fail "DMG is missing the Viewer app"

    # Do not execute the CLI for its embedded version until both payloads satisfy SpaceO's
    # repository-owned designated requirements.
    assert_publisher_signature "$cli" "$CLI_IDENTIFIER"
    assert_publisher_signature "$app" "$VIEWER_IDENTIFIER" true
    spctl --assess --type execute --verbose=4 "$cli"
    spctl --assess --type execute --verbose=4 "$app"
    assert_embedded_versions "$cli" "$app"

    hdiutil detach "$mount_point" -quiet
    ACTIVE_MOUNT=""
    rmdir "$mount_point" 2>/dev/null || true
    echo "verified signed, notarized SpaceO $VERSION distribution: $artifact"
}

package_distribution() {
    local architecture
    local output_dir
    local base_name
    local artifact
    local checksum
    local checksum_signature
    local working_artifact
    local working_checksum
    local working_checksum_signature
    local stage
    local cli
    local app
    local app_zip

    run_preflight
    architecture="$(release_architecture)"
    output_dir="$RELEASE_ROOT/$VERSION"
    base_name="SpaceO-$VERSION-macOS-$architecture"
    artifact="$output_dir/$base_name.dmg"
    checksum="$output_dir/$base_name.sha256"
    checksum_signature="$checksum.sig"

    mkdir -p "$output_dir"
    WORK_DIR="$(mktemp -d "$output_dir/.spaceo-release.XXXXXX")"
    stage="$WORK_DIR/stage"
    mkdir -p "$stage"
    working_artifact="$WORK_DIR/$base_name.dmg"
    working_checksum="$WORK_DIR/$base_name.sha256"
    working_checksum_signature="$working_checksum.sig"

    SWIFT="$SWIFT" "$REPOSITORY_ROOT/scripts/test.sh" safe
    "$SWIFT" build -c release
    "$NODE" "$REPOSITORY_ROOT/scripts/mcp-smoke.mjs" \
        "$REPOSITORY_ROOT/.build/release/spaceo"

    cli="$stage/spaceo"
    app="$stage/SpaceO Viewer.app"
    cp "$REPOSITORY_ROOT/.build/release/spaceo" "$cli"
    chmod 755 "$cli"
    codesign \
        --force \
        --identifier "$CLI_IDENTIFIER" \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$cli"

    SPACEO_VERSION="$VERSION" \
    SPACEO_DISTRIBUTION=1 \
    SPACEO_CODESIGN_IDENTITY="$SIGNING_IDENTITY" \
        "$REPOSITORY_ROOT/scripts/make-viewer-app.sh" \
        "$REPOSITORY_ROOT/.build/release/SpaceOViewer" \
        "$app"

    assert_publisher_signature "$cli" "$CLI_IDENTIFIER"
    assert_publisher_signature "$app" "$VIEWER_IDENTIFIER" true
    assert_embedded_versions "$cli" "$app"

    app_zip="$WORK_DIR/SpaceO-Viewer-$VERSION-notary.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$app_zip"
    notarize "$app_zip" "Viewer"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=4 "$app"

    cp "$REPOSITORY_ROOT/README.md" "$stage/README.md"
    cp "$REPOSITORY_ROOT/docs/INSTALL.md" "$stage/INSTALL.md"
    ln -s /Applications "$stage/Applications"

    hdiutil create \
        -volname "SpaceO $VERSION" \
        -srcfolder "$stage" \
        -format UDZO \
        -ov \
        "$working_artifact" >/dev/null

    notarize "$working_artifact" "DMG"
    xcrun stapler staple "$working_artifact"
    xcrun stapler validate "$working_artifact"

    (
        cd "$WORK_DIR"
        shasum -a 256 "$(basename "$working_artifact")" > "$(basename "$working_checksum")"
    )
    codesign \
        --force \
        --identifier "$CHECKSUM_IDENTIFIER" \
        --detached "$working_checksum_signature" \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$working_checksum"
    verify_distribution "$working_artifact"

    # Only expose the public output names after the fully verified files exist. All moves stay on
    # the release volume, preserving the stapled DMG and detached signature byte-for-byte.
    rm -f "$artifact" "$checksum" "$checksum_signature"
    mv "$working_artifact" "$artifact"
    mv "$working_checksum" "$checksum"
    mv "$working_checksum_signature" "$checksum_signature"
    (
        cd "$output_dir"
        shasum -a 256 -c "$(basename "$checksum")"
    )
    xcrun stapler validate "$artifact"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$artifact"

    echo "release artifact : $artifact"
    echo "checksum         : $checksum"
    echo "checksum signature: $checksum_signature"
}

command="${1:-help}"
case "$command" in
    check)
        check_common
        echo "release configuration is consistent for SpaceO $VERSION"
        ;;
    dry-run)
        check_common
        architecture="$(release_architecture)"
        echo "SpaceO release dry run (no build, signing, upload, or publication performed)"
        echo "version            : $VERSION"
        echo "artifact           : $RELEASE_ROOT/$VERSION/SpaceO-$VERSION-macOS-$architecture.dmg"
        echo "publisher team     : $PUBLISHER_TEAM_ID"
        if [[ -n "$SIGNING_IDENTITY" ]]; then
            echo "signing identity   : explicit input supplied"
        else
            echo "signing identity   : MISSING (publication will fail closed)"
        fi
        credential_summary
        ;;
    preflight)
        run_preflight
        ;;
    package)
        package_distribution
        ;;
    verify)
        check_common
        [[ -n "${2:-}" ]] || fail "verify requires a .dmg path"
        verify_distribution "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        fail "unknown release command: $command"
        ;;
esac
