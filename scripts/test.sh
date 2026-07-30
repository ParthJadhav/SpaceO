#!/usr/bin/env bash
# Keep deterministic tests separate from qualification that mutates the real WindowServer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT="${SWIFT:-swift}"
LIVE_TEST_PATTERN='^SpaceOKitTests\.IntegrationTests/'
LIVE_TEST_CLASS='SpaceOKitTests.IntegrationTests'

fail() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

repository_commit() {
    git -C "$REPOSITORY_ROOT" rev-parse HEAD 2>/dev/null \
        || fail "live qualification requires a Git checkout"
}

record_value() {
    local record="$1"
    local key="$2"
    local matches
    matches="$(grep -E "^${key}=" "$record" || true)"
    [[ "$(printf '%s\n' "$matches" | grep -c . || true)" -eq 1 ]] \
        || fail "qualification record must contain exactly one $key field"
    printf '%s\n' "${matches#*=}"
}

verify_live_record() {
    local record="${1:-}"
    [[ -n "$record" ]] || fail "verify-live-record requires a record path"
    [[ -f "$record" ]] || fail "live qualification record does not exist: $record"

    local expected_commit
    expected_commit="$(repository_commit)"
    [[ "$(record_value "$record" format)" == "spaceo-live-qualification-v1" ]] \
        || fail "unsupported live qualification record format"
    [[ "$(record_value "$record" commit)" == "$expected_commit" ]] \
        || fail "live qualification record does not match release commit $expected_commit"
    [[ "$(record_value "$record" platform)" == "Darwin" ]] \
        || fail "live qualification was not performed on macOS"
    [[ "$(record_value "$record" architecture)" == "arm64" ]] \
        || fail "live qualification was not performed on the release architecture (arm64)"
    [[ "$(record_value "$record" qualified_host_attested)" == "1" ]] \
        || fail "live qualification record lacks the qualified-host attestation"
    [[ "$(record_value "$record" disposable_login_attested)" == "1" ]] \
        || fail "live qualification record lacks the disposable-login attestation"
    [[ "$(record_value "$record" console_user_matches_runner)" == "1" ]] \
        || fail "live qualification did not run inside the active console login"
    [[ "$(record_value "$record" status)" == "passed" ]] \
        || fail "live qualification did not pass"

    local discovered executed skipped
    discovered="$(record_value "$record" integration_tests_discovered)"
    executed="$(record_value "$record" integration_tests_executed)"
    skipped="$(record_value "$record" integration_tests_skipped)"
    [[ "$discovered" =~ ^[1-9][0-9]*$ ]] \
        || fail "live qualification discovered no integration tests"
    [[ "$executed" == "$discovered" ]] \
        || fail "live qualification executed $executed of $discovered integration tests"
    [[ "$skipped" == "0" ]] \
        || fail "live qualification skipped $skipped integration tests"

    echo "verified live qualification for commit $expected_commit ($executed tests, none skipped)"
}

run_safe() {
    require_command "$SWIFT"
    cd "$REPOSITORY_ROOT"

    # The skip controls discovery; the false opt-ins are a second boundary if Swift's selector
    # behavior changes or somebody appends a broader filter.
    SPACEO_LIVE_QUALIFICATION=0 \
    SPACEO_DISPOSABLE_LOGIN=0 \
    SPACEO_QUALIFIED_HOST=0 \
        "$SWIFT" test --skip "$LIVE_TEST_CLASS" "$@"
}

run_live() {
    require_command "$SWIFT"
    require_command git
    [[ "$(uname -s)" == "Darwin" ]] || fail "live qualification requires macOS"
    [[ "$(uname -m)" == "arm64" ]] \
        || fail "live qualification requires the release architecture (arm64)"
    [[ "${SPACEO_LIVE_QUALIFICATION:-}" == "1" ]] \
        || fail "set SPACEO_LIVE_QUALIFICATION=1 to opt in to real WindowServer mutation"
    [[ "${SPACEO_QUALIFIED_HOST:-}" == "1" ]] \
        || fail "set SPACEO_QUALIFIED_HOST=1 only on a host reserved for live qualification"
    [[ "${SPACEO_DISPOSABLE_LOGIN:-}" == "1" ]] \
        || fail "set SPACEO_DISPOSABLE_LOGIN=1 only inside a disposable macOS login"
    [[ "$(id -u)" -ne 0 ]] || fail "live qualification must not run as root"

    local runner_user console_user console_matches
    runner_user="$(id -un)"
    console_user="$(stat -f '%Su' /dev/console)"
    console_matches=0
    [[ "$console_user" == "$runner_user" ]] && console_matches=1
    [[ "$console_matches" == "1" ]] \
        || fail "live qualification must run as the active console user"

    local commit result_file log_file os_version os_build discovered executed skipped status
    commit="$(repository_commit)"
    result_file="${SPACEO_LIVE_RESULT:-$REPOSITORY_ROOT/.build/spaceo-live-qualification.txt}"
    log_file="${SPACEO_LIVE_LOG:-$REPOSITORY_ROOT/.build/spaceo-live-qualification-tests.log}"
    os_version="$(sw_vers -productVersion)"
    os_build="$(sw_vers -buildVersion)"
    discovered=0
    executed=0
    skipped=0
    status=failed
    mkdir -p "$(dirname "$result_file")" "$(dirname "$log_file")"

    write_record() {
        local temporary="${result_file}.tmp"
        {
            echo "format=spaceo-live-qualification-v1"
            echo "commit=$commit"
            echo "platform=Darwin"
            echo "os_version=$os_version"
            echo "os_build=$os_build"
            echo "architecture=arm64"
            echo "qualified_host_attested=1"
            echo "disposable_login_attested=1"
            echo "console_user_matches_runner=$console_matches"
            echo "integration_tests_discovered=$discovered"
            echo "integration_tests_executed=$executed"
            echo "integration_tests_skipped=$skipped"
            echo "status=$status"
        } > "$temporary"
        mv "$temporary" "$result_file"
    }
    trap write_record EXIT
    write_record

    cd "$REPOSITORY_ROOT"
    local test_list
    test_list="$("$SWIFT" test list)"
    discovered="$(
        printf '%s\n' "$test_list" \
            | grep -E "$LIVE_TEST_PATTERN" \
            | wc -l \
            | tr -d '[:space:]'
    )"
    [[ "$discovered" =~ ^[1-9][0-9]*$ ]] \
        || fail "no live integration tests matched $LIVE_TEST_PATTERN"
    write_record

    set +e
    "$SWIFT" test --filter "$LIVE_TEST_CLASS" 2>&1 | tee "$log_file"
    local test_status="${PIPESTATUS[0]}"
    set -e

    local summary
    summary="$(grep -E 'Executed [0-9]+ tests?' "$log_file" | tail -1 || true)"
    [[ -n "$summary" ]] || fail "live test runner produced no XCTest execution summary"
    executed="$(sed -E 's/.*Executed ([0-9]+) tests?.*/\1/' <<<"$summary")"
    if [[ "$summary" =~ with[[:space:]]+([0-9]+)[[:space:]]+tests?[[:space:]]+skipped ]]; then
        skipped="${BASH_REMATCH[1]}"
    else
        skipped=0
    fi
    write_record

    [[ "$test_status" -eq 0 ]] || fail "live integration tests failed"
    [[ "$executed" == "$discovered" ]] \
        || fail "live qualification executed $executed of $discovered discovered tests"
    [[ "$skipped" == "0" ]] \
        || fail "live qualification skipped $skipped tests; missing prerequisites are a failure"

    status=passed
    write_record
    trap - EXIT
    verify_live_record "$result_file"
}

usage() {
    cat <<'USAGE'
usage: scripts/test.sh COMMAND

Commands:
  safe                      Run deterministic tests and exclude IntegrationTests.
  live                      Run every IntegrationTests case and fail on any skip.
  verify-live-record FILE   Verify a passing live record for the current commit.

`live` mutates the real WindowServer, launches apps, and sends input. It requires all of:
SPACEO_LIVE_QUALIFICATION=1, SPACEO_QUALIFIED_HOST=1, and SPACEO_DISPOSABLE_LOGIN=1.
USAGE
}

command="${1:-help}"
shift || true
case "$command" in
    safe)
        run_safe "$@"
        ;;
    live)
        [[ "$#" -eq 0 ]] || fail "live qualification does not accept partial test selectors"
        run_live
        ;;
    verify-live-record)
        [[ "$#" -eq 1 ]] || fail "verify-live-record requires exactly one record path"
        verify_live_record "$1"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        fail "unknown test command: $command"
        ;;
esac
