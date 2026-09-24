#!/usr/bin/env bash
# Keep deterministic tests separate from tests that mutate the real WindowServer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT="${SWIFT:-swift}"
NODE="${NODE:-node}"
LIVE_TEST_CLASS='SpaceOKitTests.IntegrationTests'

fail() { echo "error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"; }

run_safe() {
    require_command "$SWIFT"
    require_command "$NODE"
    cd "$REPOSITORY_ROOT"
    "$SWIFT" test --skip "$LIVE_TEST_CLASS" "$@"
    bash "$REPOSITORY_ROOT/Tests/ViewerInstallTests.sh"
    "$NODE" --test "$REPOSITORY_ROOT/Tests/ComputerUseEvidenceTests.mjs" \
        "$REPOSITORY_ROOT/Tests/PresentationEvidenceTests.mjs" \
        "$REPOSITORY_ROOT/Tests/JournalReportTests.mjs"
}

run_live() {
    require_command "$SWIFT"
    [[ "$(uname -s)" == "Darwin" ]] || fail "live tests require macOS"

    # Off by default: on a developer box the suite is expected to skip itself when the TCC grants
    # are absent, and `make test-live` keeps that behaviour. Automation that claims to qualify a
    # host passes --require-full, which makes a skipped or unexecuted test a failure.
    local require_full=0
    local -a swift_arguments=()
    local argument
    for argument in "$@"; do
        case "$argument" in
            --require-full) require_full=1 ;;
            *) swift_arguments+=("$argument") ;;
        esac
    done

    cd "$REPOSITORY_ROOT"
    if (( ! require_full )); then
        "$SWIFT" test --filter "$LIVE_TEST_CLASS" ${swift_arguments+"${swift_arguments[@]}"}
        return
    fi

    local log="${SPACEO_LIVE_LOG:-}"
    if [[ -z "$log" ]]; then
        # BSD mktemp(1) requires the X placeholder to end the template. A suffix after the Xs
        # turns this into a literal filename, so an interrupted prior run can poison every later
        # invocation with "File exists" instead of giving each run its own log.
        log="$(mktemp "${TMPDIR:-/tmp}/spaceo-live-tests.XXXXXX")"
        trap 'rm -f "$log"' RETURN
    fi

    # `set +e` rather than `|| true`: appending `|| true` to the pipeline makes PIPESTATUS describe
    # the `true` that ran instead of the compiler, silently turning a failed run into a passing one.
    local status=0
    set +e
    "$SWIFT" test --filter "$LIVE_TEST_CLASS" ${swift_arguments+"${swift_arguments[@]}"} 2>&1 \
        | tee "$log"
    status="${PIPESTATUS[0]}"
    set -e

    # Runs before the exit status is honoured: `swift test` exits 0 both when the filter matches
    # nothing and when every test skips, so the log is the only evidence that anything ran.
    bash "$SCRIPT_DIR/check-live-test-run.sh" "$log"
    return "$status"
}

usage() {
    cat <<'USAGE'
usage: scripts/test.sh COMMAND

Commands:
  safe   Run deterministic tests and exclude IntegrationTests.
  live   Run IntegrationTests against the real WindowServer.

Options for `live`:
  --require-full   Fail when any live test skips or when the filter selects fewer tests
                   than the suite defines. For a host that claims to qualify SpaceO, a
                   skipped live test is a failure rather than a pass.

`live` creates virtual displays, launches applications, and sends input in the current
graphical login. Tests that cannot meet their runtime prerequisites skip themselves.
Set SPACEO_LIVE_LOG to retain the run log at a chosen path.
USAGE
}

command="${1:-help}"
shift || true
case "$command" in
    safe) run_safe "$@" ;;
    live) run_live "$@" ;;
    help|-h|--help) usage ;;
    *) usage >&2; fail "unknown test command: $command" ;;
esac
