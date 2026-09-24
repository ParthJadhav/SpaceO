#!/usr/bin/env bash
# Fail early when a hosted runner drifts to a compiler that cannot parse SpaceO's concurrency API.
set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

required_xcode="${SPACEO_REQUIRED_XCODE_VERSION:-}"
required_swift="${SPACEO_REQUIRED_SWIFT_VERSION:-}"
[[ -n "$required_xcode" ]] \
    || fail "SPACEO_REQUIRED_XCODE_VERSION must pin the workflow Xcode version"
[[ -n "$required_swift" ]] \
    || fail "SPACEO_REQUIRED_SWIFT_VERSION must pin the workflow Swift language toolchain"
[[ -n "${DEVELOPER_DIR:-}" ]] \
    || fail "DEVELOPER_DIR must select the pinned Xcode installation"
[[ -d "$DEVELOPER_DIR" ]] \
    || fail "pinned Xcode developer directory is unavailable: $DEVELOPER_DIR"

actual_xcode="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
actual_swift="$(swift --version | awk 'NR == 1 { print $4 }')"
[[ "$actual_xcode" == "$required_xcode" ]] \
    || fail "Xcode $required_xcode is required, but DEVELOPER_DIR selected ${actual_xcode:-unknown}"
[[ "$actual_swift" == "$required_swift" || "$actual_swift" == "$required_swift".* ]] \
    || fail "Swift $required_swift.x is required for nonisolated(nonsending), got ${actual_swift:-unknown}"

echo "verified pinned release toolchain: Xcode $actual_xcode, Swift $actual_swift"
