#!/usr/bin/env bash
# Exercises scripts/check-live-test-run.sh against fixture logs.
#
# The gate exists because `swift test` exits 0 when nothing ran. A gate that itself silently
# stopped catching that would restore the original defect, so every rejection path is asserted
# here rather than trusted.
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPOSITORY_ROOT/scripts/check-live-test-run.sh"

fail() { echo "live test gate test failed: $*" >&2; exit 1; }

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaceo-live-gate.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

# A stand-in for IntegrationTests.swift: only the `func test...` count is read from it.
write_source() {
    local path="$1"
    local count="$2"
    {
        echo 'final class IntegrationTests: XCTestCase {'
        # A helper that is not a test must not inflate the expected count.
        echo '    private func testingHelperNotATest(_ value: Int) -> Int { value }'
        for (( index = 1; index <= count; index++ )); do
            echo "    func testLive${index}() throws {}"
        done
        echo '}'
    } >"$path"
}

case_line() { echo "Test Case '-[SpaceOKitTests.IntegrationTests testLive$1]' $2 (0.512 seconds)."; }

# Builds a log with the requested mix of outcomes, wrapped in the surrounding suite chatter that a
# real run emits so the parser is exercised against realistic noise.
write_log() {
    local path="$1" passed="$2" failed="$3" skipped="$4"
    local index=0
    {
        echo "Test Suite 'Selected tests' started at 2026-08-02 10:00:00.000"
        echo "Test Suite 'SpaceOKitPackageTests.xctest' started at 2026-08-02 10:00:00.001"
        echo "Test Suite 'IntegrationTests' started at 2026-08-02 10:00:00.001"
        for (( i = 0; i < passed; i++ )); do
            index=$(( index + 1 ))
            echo "Test Case '-[SpaceOKitTests.IntegrationTests testLive${index}]' started."
            case_line "$index" passed
        done
        for (( i = 0; i < failed; i++ )); do
            index=$(( index + 1 ))
            echo "Test Case '-[SpaceOKitTests.IntegrationTests testLive${index}]' started."
            echo "$REPOSITORY_ROOT/Tests/SpaceOKitTests/IntegrationTests.swift:51: -[SpaceOKitTests.IntegrationTests testLive${index}] : XCTAssertTrue failed - leaked virtual display(s): [280]"
            case_line "$index" failed
        done
        for (( i = 0; i < skipped; i++ )); do
            index=$(( index + 1 ))
            echo "Test Case '-[SpaceOKitTests.IntegrationTests testLive${index}]' started."
            echo "$REPOSITORY_ROOT/Tests/SpaceOKitTests/IntegrationTests.swift:22: -[SpaceOKitTests.IntegrationTests testLive${index}] : Test skipped - SpaceO cannot drive sessions on this host:"
            case_line "$index" skipped
        done
        echo "Test Suite 'IntegrationTests' passed at 2026-08-02 10:00:04.000"
        echo "	 Executed $(( passed + failed + skipped )) tests, with ${skipped} tests skipped and ${failed} failures (0 unexpected) in 4.000 (4.001) seconds"
    } >"$path"
}

run_check() {
    local source="$1" log="$2"
    SPACEO_LIVE_TEST_SOURCE="$source" bash "$CHECK" "$log" 2>&1
}

assert_accepts() {
    local label="$1" source="$2" log="$3"
    local output
    if ! output="$(run_check "$source" "$log")"; then
        fail "$label: expected the gate to accept the run, but it rejected it:
$output"
    fi
}

assert_rejects() {
    local label="$1" source="$2" log="$3" expected_message="$4"
    local output
    if output="$(run_check "$source" "$log")"; then
        fail "$label: expected the gate to reject the run, but it exited 0:
$output"
    fi
    grep -Fq "$expected_message" <<<"$output" \
        || fail "$label: rejection did not explain the cause (wanted \"$expected_message\"):
$output"
}

SOURCE_16="$TEST_ROOT/IntegrationTests.swift"
write_source "$SOURCE_16" 16

# A fully executed run is the only shape that passes.
write_log "$TEST_ROOT/all-passed.log" 16 0 0
assert_accepts "16 of 16 executed" "$SOURCE_16" "$TEST_ROOT/all-passed.log"

# The defect this ticket was filed for: every test skips, `swift test` exits 0.
write_log "$TEST_ROOT/all-skipped.log" 0 0 16
assert_rejects "every test skipped" "$SOURCE_16" "$TEST_ROOT/all-skipped.log" "16 live test(s) skipped"

# A single skip hides one test's worth of coverage and must not be averaged away.
write_log "$TEST_ROOT/one-skipped.log" 15 0 1
assert_rejects "one test skipped" "$SOURCE_16" "$TEST_ROOT/one-skipped.log" "1 live test(s) skipped"

# A filter that matches nothing: no per-case lines at all, exit 0 from swift test.
write_log "$TEST_ROOT/empty.log" 0 0 0
assert_rejects "filter matched nothing" "$SOURCE_16" "$TEST_ROOT/empty.log" "no live test produced a result"

# A filter that quietly selects a subset leaves the rest unverified while looking green.
write_log "$TEST_ROOT/subset.log" 3 0 0
assert_rejects "filter selected a subset" "$SOURCE_16" "$TEST_ROOT/subset.log" "3 live test(s) executed but 16 are defined"

# A real failure still fails, and counts as executed rather than missing.
write_log "$TEST_ROOT/failure.log" 15 1 0
assert_rejects "a live test failed" "$SOURCE_16" "$TEST_ROOT/failure.log" "1 live test(s) failed"

# Adding a live test raises the bar automatically; a stale run no longer satisfies the gate.
SOURCE_17="$TEST_ROOT/IntegrationTests17.swift"
write_source "$SOURCE_17" 17
assert_rejects "suite grew, run did not" "$SOURCE_17" "$TEST_ROOT/all-passed.log" \
    "16 live test(s) executed but 17 are defined"

# A source with no tests must not silently satisfy a run that executed nothing.
SOURCE_0="$TEST_ROOT/IntegrationTests0.swift"
write_source "$SOURCE_0" 0
assert_rejects "no tests defined" "$SOURCE_0" "$TEST_ROOT/empty.log" "found no test methods"

# A missing log is an error, not an absence of evidence to shrug at.
assert_rejects "log missing" "$SOURCE_16" "$TEST_ROOT/does-not-exist.log" "cannot read live test log"

# The real suite source must parse to a plausible count, or the gate is enforcing nothing in CI.
real_count="$(grep -cE '^[[:space:]]*func[[:space:]]+test[A-Za-z0-9_]*[[:space:]]*\(' \
    "$REPOSITORY_ROOT/Tests/SpaceOKitTests/IntegrationTests.swift")"
(( real_count > 0 )) \
    || fail "IntegrationTests.swift parses to 0 test methods; the gate would enforce nothing"
write_log "$TEST_ROOT/real-count.log" "$real_count" 0 0
assert_accepts "real suite count parses" \
    "$REPOSITORY_ROOT/Tests/SpaceOKitTests/IntegrationTests.swift" "$TEST_ROOT/real-count.log"

# The suite must keep its display-leak baseline ahead of the skip, or a skipped run silently stops
# checking for phantom displays -- the second half of the defect this gate was added for.
suite_setup="$(sed -n '/override func setUpWithError/,/^    }/p' \
    "$REPOSITORY_ROOT/Tests/SpaceOKitTests/IntegrationTests.swift")"
# Anchored on the statements, not on prose: the surrounding comments name both by design.
baseline_line="$(grep -nE '^[[:space:]]*hasDisplayBaseline = true' <<<"$suite_setup" | head -1 | cut -d: -f1)"
skip_line="$(grep -nE '^[[:space:]]*try XCTSkipUnless\(' <<<"$suite_setup" | head -1 | cut -d: -f1)"
[[ -n "$baseline_line" && -n "$skip_line" ]] \
    || fail "could not locate the display baseline and the skip in setUpWithError"
(( baseline_line < skip_line )) \
    || fail "setUpWithError takes its display baseline after XCTSkipUnless, so tearDownWithError's leaked-display assertion is disarmed whenever the suite skips"

# --- scripts/test.sh live plumbing -------------------------------------------------------------
#
# The gate is only useful if `live --require-full` actually reaches it. A stub compiler stands in
# for `swift test` so the wiring -- flag parsing, tee, PIPESTATUS, and the check's exit status --
# is exercised without a WindowServer.

STUB_BIN="$TEST_ROOT/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/swift" <<'STUB'
#!/usr/bin/env bash
# Emits a canned XCTest transcript. STUB_LOG is the transcript, STUB_EXIT the status to report.
[[ "${1:-}" == "test" ]] || { echo "stub swift: unexpected invocation: $*" >&2; exit 99; }
echo "stub swift invoked with: $*" >"${STUB_INVOCATION:-/dev/null}"
cat "$STUB_LOG"
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$STUB_BIN/swift"

run_test_sh_live() {
    local stub_log="$1" stub_exit="$2"
    shift 2
    STUB_LOG="$stub_log" STUB_EXIT="$stub_exit" STUB_INVOCATION="$TEST_ROOT/invocation.txt" \
        SWIFT="$STUB_BIN/swift" SPACEO_LIVE_LOG="$TEST_ROOT/live.log" \
        bash "$REPOSITORY_ROOT/scripts/test.sh" live "$@" 2>&1
}

# A run where every test skipped must fail even though the compiler reported success.
if output="$(run_test_sh_live "$TEST_ROOT/all-skipped.log" 0 --require-full)"; then
    fail "test.sh live --require-full accepted a run in which every test skipped:
$output"
fi
grep -Fq "live test(s) skipped" <<<"$output" \
    || fail "test.sh live --require-full did not reach the skip gate:
$output"

# --require-full must be consumed by test.sh, never forwarded to swift.
grep -Fq -- "--require-full" "$TEST_ROOT/invocation.txt" \
    && fail "test.sh forwarded --require-full to swift test"
grep -Fq -- "--filter" "$TEST_ROOT/invocation.txt" \
    || fail "test.sh did not filter to the live suite: $(cat "$TEST_ROOT/invocation.txt")"

# Unrecognised arguments still reach swift test.
run_test_sh_live "$TEST_ROOT/real-count.log" 0 --require-full --parallel >/dev/null 2>&1 || true
grep -Fq -- "--parallel" "$TEST_ROOT/invocation.txt" \
    || fail "test.sh dropped a passthrough argument: $(cat "$TEST_ROOT/invocation.txt")"

# A fully executed run passes, and SPACEO_LIVE_LOG retains the transcript for the CI artifact.
run_test_sh_live "$TEST_ROOT/real-count.log" 0 --require-full >/dev/null \
    || fail "test.sh live --require-full rejected a fully executed run"
grep -Fq "Test Case " "$TEST_ROOT/live.log" \
    || fail "SPACEO_LIVE_LOG did not retain the run transcript"

# The automatically-created log must use a portable BSD mktemp template. A stale literal path is
# what older test.sh versions generated when they put `.log` after the X placeholder.
mkdir -p "$TEST_ROOT/tmp"
: >"$TEST_ROOT/tmp/spaceo-live-tests.XXXXXX.log"
STUB_LOG="$TEST_ROOT/real-count.log" STUB_EXIT=0 \
    STUB_INVOCATION="$TEST_ROOT/invocation-auto-log.txt" SWIFT="$STUB_BIN/swift" \
    TMPDIR="$TEST_ROOT/tmp" bash "$REPOSITORY_ROOT/scripts/test.sh" live --require-full \
    >/dev/null \
    || fail "test.sh could not create a unique automatic live-test log"

# A genuine test failure must survive the gate rather than being masked by tee.
if run_test_sh_live "$TEST_ROOT/real-count.log" 1 --require-full >/dev/null 2>&1; then
    fail "test.sh live --require-full reported success for a run that swift test failed"
fi

# Without --require-full the developer default is unchanged: skips do not fail the run.
run_test_sh_live "$TEST_ROOT/all-skipped.log" 0 >/dev/null 2>&1 \
    || fail "test.sh live (no flag) must keep skipping benign, matching the Round 9 posture"

echo "live test gate tests passed"
