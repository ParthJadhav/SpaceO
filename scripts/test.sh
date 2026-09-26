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
    require_command python3
    cd "$REPOSITORY_ROOT"
    "$SWIFT" test --skip "$LIVE_TEST_CLASS" "$@"
    bash "$REPOSITORY_ROOT/Tests/ViewerInstallTests.sh"
    python3 "$REPOSITORY_ROOT/Tests/LiveTestSupervisorTests.py"
    "$NODE" --test "$REPOSITORY_ROOT/Tests/ComputerUseEvidenceTests.mjs" \
        "$REPOSITORY_ROOT/Tests/PresentationEvidenceTests.mjs" \
        "$REPOSITORY_ROOT/Tests/JournalReportTests.mjs"
}

run_live() {
    require_command "$SWIFT"
    require_command python3
    require_command xcrun
    [[ "${SPACEO_LIVE_TESTS:-}" == 1 ]] || fail "live tests require SPACEO_LIVE_TESTS=1 on a reserved host; see docs/LIVE_TESTS.md"
    [[ "$(uname -s)" == "Darwin" ]] || fail "live tests require macOS"

    # Once explicitly opted in, missing TCC prerequisites may skip. Qualification additionally
    # requires --require-full so a skipped or unexecuted test cannot be mistaken for evidence.
    local require_full=0
    local skip_build=0
    local test_filter="$LIVE_TEST_CLASS"
    local test_case=""
    local -a swift_arguments=()
    local argument
    for argument in "$@"; do
        case "$argument" in
            --require-full) require_full=1 ;;
            --skip-build) skip_build=1 ;;
            --case=test[A-Za-z0-9_]*)
                test_case="${argument#--case=}"
                [[ "$test_case" =~ ^test[A-Za-z0-9_]+$ ]] || fail "invalid live test case"
                test_filter="$LIVE_TEST_CLASS/$test_case" ;;
            --filter|--filter=*) fail "use --case=testName to select one live test" ;;
            --parallel|--parallel=*|--num-workers|--num-workers=*)
                fail "parallel live tests are unsafe; display lifecycle work must be serial" ;;
            *) swift_arguments+=("$argument") ;;
        esac
    done
    if (( require_full )) && [[ -n "$test_case" ]]; then
        fail "--case cannot qualify the full suite; omit --require-full for a focused run"
    fi

    cd "$REPOSITORY_ROOT"
    # SwiftPM captures XCTest output and starts it in another process group. Supervise XCTest
    # itself so case-start messages are immediate and SIGSTOP reaches the process doing IPC.
    if (( ! skip_build )); then
        "$SWIFT" build --build-tests ${swift_arguments+"${swift_arguments[@]}"}
    fi
    local bin_path xctest test_bundle
    bin_path="$("$SWIFT" build --show-bin-path ${swift_arguments+"${swift_arguments[@]}"})"
    xctest="$(xcrun --find xctest)"
    # SwiftPM versions differ in whether the product uses the package or test-target name.
    # Resolve the sole generated bundle and fail closed on ambiguity or a stale second product.
    local -a test_bundles=("$bin_path"/*.xctest)
    (( ${#test_bundles[@]} == 1 )) && [[ -d "${test_bundles[0]}" ]] \
        || fail "expected exactly one built XCTest bundle"
    test_bundle="${test_bundles[0]}"
    local log="${SPACEO_LIVE_LOG:-}"
    if [[ -z "$log" ]]; then
        # BSD mktemp(1) requires the X placeholder to end the template. A suffix after the Xs
        # turns this into a literal filename, so an interrupted prior run can poison every later
        # invocation with "File exists" instead of giving each run its own log.
        log="$(mktemp "${TMPDIR:-/tmp}/spaceo-live-tests.XXXXXX")"
        echo "live test log retained at: $log"
    fi

    local status=0
    NSUnbufferedIO=YES python3 "$SCRIPT_DIR/live-test-supervisor.py" --log "$log" -- \
        "$xctest" -XCTest "$test_filter" "$test_bundle" || status=$?
    if (( require_full )); then
        bash "$SCRIPT_DIR/check-live-test-run.sh" "$log" || return 1
    elif [[ -n "$test_case" ]]; then
        bash "$SCRIPT_DIR/check-live-test-run.sh" "$log" "--case=$test_case" || return 1
    fi
    return "$status"
}

usage() {
    cat <<'USAGE'
usage: scripts/test.sh COMMAND

Commands:
  safe   Run deterministic tests and exclude IntegrationTests.
  live   Run IntegrationTests against the real WindowServer.

Options for `live`:
  --case=testName  Require one passing result for exactly this IntegrationTests method.
  --require-full   Fail when any live test skips or when the filter selects fewer tests
                   than the suite defines. For a host that claims to qualify SpaceO, a
                   skipped live test is a failure rather than a pass.

`live` creates virtual displays, launches applications, and sends input in the current
graphical login. Tests that cannot meet their runtime prerequisites skip themselves.
Requires SPACEO_LIVE_TESTS=1 on a reserved host. Parallel execution is refused.
Runs stop after the first failure. A hung process group is suspended for inspection,
not killed automatically. Logs are always retained; SPACEO_LIVE_LOG chooses the path.
USAGE
}

command="${1:-help}"
shift || true
case "$command" in
    safe) run_safe "$@" ;;
    # Exit inside the already-parsed case: editing this source while a long run is in flight
    # must not make bash resume reading at a shifted byte offset after the function returns.
    live) run_live "$@"; exit $? ;;
    help|-h|--help) usage ;;
    *) usage >&2; fail "unknown test command: $command" ;;
esac
