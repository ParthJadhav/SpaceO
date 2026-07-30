#!/usr/bin/env bash
# Keep deterministic tests separate from tests that mutate the real WindowServer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT="${SWIFT:-swift}"
LIVE_TEST_CLASS='SpaceOKitTests.IntegrationTests'

fail() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

run_safe() {
    require_command "$SWIFT"
    cd "$REPOSITORY_ROOT"
    "$SWIFT" test --skip "$LIVE_TEST_CLASS" "$@"
}

run_live() {
    require_command "$SWIFT"
    [[ "$(uname -s)" == "Darwin" ]] || fail "live tests require macOS"
    cd "$REPOSITORY_ROOT"
    "$SWIFT" test --filter "$LIVE_TEST_CLASS" "$@"
}

usage() {
    cat <<'USAGE'
usage: scripts/test.sh COMMAND

Commands:
  safe   Run deterministic tests and exclude IntegrationTests.
  live   Run IntegrationTests against the real WindowServer.

`live` creates virtual displays, launches applications, and sends input in the current
graphical login. Tests that cannot meet their runtime prerequisites skip themselves.
USAGE
}

command="${1:-help}"
shift || true
case "$command" in
    safe)
        run_safe "$@"
        ;;
    live)
        run_live "$@"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        fail "unknown test command: $command"
        ;;
esac
