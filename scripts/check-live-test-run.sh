#!/usr/bin/env bash
# Fails a live WindowServer run that did not actually execute its tests.
#
# `swift test --filter` exits 0 when the filter matches nothing, and XCTest exits 0 when every
# test skips itself. Both outcomes are indistinguishable from a green run at the exit code, which
# is the whole reason the live suite could sit unexecuted while release automation reported
# success. This turns "nothing ran" and "everything skipped" into loud failures.
#
# The expected test count is derived from the suite source rather than hardcoded, so adding a live
# test automatically raises the bar and a filter that silently selects a subset is caught.
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the test suite can point the check at fixture logs and fixture sources.
LIVE_TEST_SOURCE="${SPACEO_LIVE_TEST_SOURCE:-$REPOSITORY_ROOT/Tests/SpaceOKitTests/IntegrationTests.swift}"
LIVE_TEST_CLASS="${SPACEO_LIVE_TEST_CLASS:-IntegrationTests}"

fail() { echo "live test run check failed: $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
usage: scripts/check-live-test-run.sh LOG_FILE [--case=testName]

Asserts that a `scripts/test.sh live` log shows every live test actually executing:
no skips, no silently empty filter, and a count matching the suite source.
With --case, require exactly one passing result for that defined method instead.
USAGE
}

case "${1:-}" in
    "") usage >&2; exit 2 ;;
    -h|--help) usage; exit 0 ;;
esac

log="$1"
[[ -r "$log" ]] || fail "cannot read live test log: $log"
[[ -r "$LIVE_TEST_SOURCE" ]] || fail "cannot read live test source: $LIVE_TEST_SOURCE"

if (( $# > 1 )); then
    [[ $# == 2 && "$2" =~ ^--case=test[A-Za-z0-9_]+$ ]] || fail "invalid focused case option"
    focused_case="${2#--case=}"
    grep -Eq "^[[:space:]]*func[[:space:]]+${focused_case}[[:space:]]*\\(" "$LIVE_TEST_SOURCE" \
        || fail "requested case is not defined: $focused_case"
    focused_passed="$(grep -cE "Test Case '[^']*${LIVE_TEST_CLASS}[.[:space:]]${focused_case}\\]?' passed " "$log" || true)"
    all_results="$(grep -cE "Test Case '[^']*${LIVE_TEST_CLASS}[.[:space:]][^']*' (passed|failed|skipped) " "$log" || true)"
    (( focused_passed == 1 && all_results == 1 )) \
        || fail "focused run requires exactly one passing result for $focused_case; got $focused_passed matching passes and $all_results total results"
    echo "live test run check passed: focused case $focused_case executed and passed"
    exit 0
fi

# Per-case result lines are unambiguous. The per-suite "Executed N tests" summary is not: a run
# prints one for the class, one for the bundle, and one for "Selected tests", and a filter that
# matches nothing still prints a zero summary that reads like a pass.
count_case_lines() {
    local outcome="$1"
    grep -cE "Test Case '[^']*${LIVE_TEST_CLASS}[.[:space:]][^']*' ${outcome}" "$log" || true
}

expected="$(grep -cE '^[[:space:]]*func[[:space:]]+test[A-Za-z0-9_]*[[:space:]]*\(' "$LIVE_TEST_SOURCE" || true)"
passed="$(count_case_lines passed)"
failed="$(count_case_lines failed)"
skipped="$(count_case_lines skipped)"
executed=$(( passed + failed ))

echo "live test run: ${executed} executed (${passed} passed, ${failed} failed), ${skipped} skipped, ${expected} defined in ${LIVE_TEST_SOURCE#"$REPOSITORY_ROOT"/}"

(( expected > 0 )) || fail "found no test methods in ${LIVE_TEST_SOURCE#"$REPOSITORY_ROOT"/}; the check has nothing to enforce"

if (( executed == 0 && skipped == 0 )); then
    fail "no live test produced a result. The filter matched nothing, or the run never started. \
This exits 0 on its own, which is exactly the silent pass this check exists to prevent."
fi

if (( skipped > 0 )); then
    fail "${skipped} live test(s) skipped. A skipped live test proves nothing about the \
WindowServer, so on a host that claims to qualify it is a failure, not a pass. Check \`spaceo \
doctor\`: driving sessions needs the virtual-display, space-query, per-pid-events, ax-window-id, \
and accessibility grants."
fi

if (( executed != expected )); then
    fail "${executed} live test(s) executed but ${expected} are defined. The filter is selecting \
a subset, so the unselected tests are silently unverified."
fi

if (( failed > 0 )); then
    fail "${failed} live test(s) failed"
fi

echo "live test run check passed: all ${expected} live tests executed against the real WindowServer"
