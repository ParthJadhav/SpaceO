#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SCRIPT="$REPOSITORY_ROOT/scripts/release.sh"
RELEASE_WORKFLOW="$REPOSITORY_ROOT/.github/workflows/release.yml"
PUBLISHER_TEAM_ID="75LRT8TRQY"

fail() {
    echo "release security test failed: $*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local expected="$2"
    grep -F "$expected" "$file" >/dev/null \
        || fail "$file does not contain required policy: $expected"
}

# Keep the privileged workflow's source selection auditable without requiring a YAML parser.
assert_contains "$RELEASE_WORKFLOW" "format('refs/tags/{0}', inputs.release_tag)"
assert_contains "$RELEASE_WORKFLOW" "persist-credentials: false"
assert_contains "$RELEASE_WORKFLOW" 'release_ref="refs/tags/$SPACEO_RELEASE_TAG"'
assert_contains "$RELEASE_WORKFLOW" 'show-ref --verify --quiet "$release_ref"'
assert_contains "$RELEASE_WORKFLOW" 'merge-base --is-ancestor "$release_commit" "$default_branch_commit"'
assert_contains "$RELEASE_WORKFLOW" '[[ "$remote_tag_object" == "$EXPECTED_TAG_OBJECT" ]]'
assert_contains "$RELEASE_WORKFLOW" 'signature=$signature'

# The verifier's trust anchor must be repository-owned, not learned from the artifact.
assert_contains "$RELEASE_SCRIPT" "PUBLISHER_TEAM_ID=\"$PUBLISHER_TEAM_ID\""
assert_contains "$RELEASE_SCRIPT" 'certificate leaf[subject.OU]'
assert_contains "$RELEASE_SCRIPT" 'CHECKSUM_IDENTIFIER="dev.spaceo.release-checksum"'

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaceo-release-security.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
MOCK_BIN="$TEST_ROOT/bin"
FIXTURE_DIR="$TEST_ROOT/fixture"
mkdir -p "$MOCK_BIN" "$FIXTURE_DIR"

cat > "$MOCK_BIN/codesign" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
team="${FAKE_TEAM_ID:?}"
identifier="dev.spaceo.cli"
is_display=false
has_requirement=false
previous=""
for argument in "$@"; do
    [[ "$argument" == "--display" ]] && is_display=true
    [[ "$argument" == "-R" || "$previous" == "-R" ]] && has_requirement=true
    previous="$argument"
done
subject="${!#}"
if [[ "$subject" == *.sha256 ]]; then
    identifier="dev.spaceo.release-checksum"
elif [[ "$subject" == *.app ]]; then
    identifier="dev.spaceo.viewer"
fi
if [[ "$has_requirement" == true && "$team" != "75LRT8TRQY" ]]; then
    exit 1
fi
if [[ "$is_display" == true ]]; then
    cat <<DETAILS
Executable=$subject
Identifier=$identifier
CodeDirectory v=20500 size=400 flags=0x10000(runtime)
Authority=Developer ID Application: Fixture ($team)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=1 Jan 2026 at 12:00:00 AM
TeamIdentifier=$team
DETAILS
fi
MOCK

cat > "$MOCK_BIN/hdiutil" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "attach" ]] || exit 0
mount_point=""
while (( $# > 0 )); do
    if [[ "$1" == "-mountpoint" ]]; then
        mount_point="$2"
        break
    fi
    shift
done
[[ -n "$mount_point" ]]
mkdir -p "$mount_point/SpaceO Viewer.app/Contents"
cat > "$mount_point/spaceo" <<'CLI'
#!/usr/bin/env bash
printf 'executed\n' > "${EXECUTION_MARKER:?}"
printf '{"version":"%s"}\n' "${TEST_RELEASE_VERSION:?}"
CLI
chmod +x "$mount_point/spaceo"
touch "$mount_point/SpaceO Viewer.app/Contents/Info.plist"
MOCK

cat > "$MOCK_BIN/plutil" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${TEST_RELEASE_VERSION:?}"
MOCK

for command in security spctl ditto; do
    cat > "$MOCK_BIN/$command" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
done

cat > "$MOCK_BIN/xcrun" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--find" ]]; then
    printf '/usr/bin/true\n'
fi
exit 0
MOCK

chmod +x "$MOCK_BIN"/*

version="$(tr -d '\r\n' < "$REPOSITORY_ROOT/VERSION")"
artifact="$FIXTURE_DIR/SpaceO-$version-macOS-arm64.dmg"
checksum="${artifact%.dmg}.sha256"
signature="$checksum.sig"
touch "$artifact" "$signature"
(
    cd "$FIXTURE_DIR"
    shasum -a 256 "$(basename "$artifact")" > "$(basename "$checksum")"
)

wrong_marker="$TEST_ROOT/wrong-publisher-executed"
if PATH="$MOCK_BIN:$PATH" \
   SWIFT=true \
   NODE=true \
   FAKE_TEAM_ID="ABCDE12345" \
   EXECUTION_MARKER="$wrong_marker" \
   TEST_RELEASE_VERSION="$version" \
   bash "$RELEASE_SCRIPT" verify "$artifact" >/dev/null 2>&1; then
    fail "a non-SpaceO Developer ID team passed distribution verification"
fi
[[ ! -e "$wrong_marker" ]] \
    || fail "the wrong-publisher CLI executed before publisher authentication"

wrong_name_marker="$TEST_ROOT/wrong-checksum-name-executed"
artifact_digest="$(shasum -a 256 "$artifact" | awk '{ print $1 }')"
printf '%s  other.dmg\n' "$artifact_digest" > "$checksum"
if PATH="$MOCK_BIN:$PATH" \
   SWIFT=true \
   NODE=true \
   FAKE_TEAM_ID="$PUBLISHER_TEAM_ID" \
   EXECUTION_MARKER="$wrong_name_marker" \
   TEST_RELEASE_VERSION="$version" \
   bash "$RELEASE_SCRIPT" verify "$artifact" >/dev/null 2>&1; then
    fail "an authenticated checksum naming a different artifact was accepted"
fi
[[ ! -e "$wrong_name_marker" ]] \
    || fail "the CLI executed before checksum filename validation"
(
    cd "$FIXTURE_DIR"
    shasum -a 256 "$(basename "$artifact")" > "$(basename "$checksum")"
)

publisher_marker="$TEST_ROOT/publisher-executed"
PATH="$MOCK_BIN:$PATH" \
SWIFT=true \
NODE=true \
FAKE_TEAM_ID="$PUBLISHER_TEAM_ID" \
EXECUTION_MARKER="$publisher_marker" \
TEST_RELEASE_VERSION="$version" \
    bash "$RELEASE_SCRIPT" verify "$artifact" >/dev/null
[[ -f "$publisher_marker" ]] \
    || fail "the authenticated publisher artifact did not preserve version verification"

echo "release security policy tests passed"
