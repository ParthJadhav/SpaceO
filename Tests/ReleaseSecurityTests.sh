#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SCRIPT="$REPOSITORY_ROOT/scripts/release.sh"
RELEASE_WORKFLOW="$REPOSITORY_ROOT/.github/workflows/release.yml"
CI_WORKFLOW="$REPOSITORY_ROOT/.github/workflows/ci.yml"
TOOLCHAIN_SCRIPT="$REPOSITORY_ROOT/scripts/check-swift-toolchain.sh"
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

assert_text_excludes() {
    local text="$1"
    local forbidden="$2"
    if grep -F "$forbidden" <<<"$text" >/dev/null; then
        fail "policy text unexpectedly contains: $forbidden"
    fi
}

# Keep the privileged workflow's source selection auditable without requiring a YAML parser.
assert_contains "$RELEASE_WORKFLOW" "format('refs/tags/{0}', inputs.release_tag)"
assert_contains "$RELEASE_WORKFLOW" "persist-credentials: false"
assert_contains "$RELEASE_WORKFLOW" 'release_ref="refs/tags/$SPACEO_RELEASE_TAG"'
assert_contains "$RELEASE_WORKFLOW" 'show-ref --verify --quiet "$release_ref"'
assert_contains "$RELEASE_WORKFLOW" 'merge-base --is-ancestor "$release_commit" "$default_branch_commit"'
assert_contains "$RELEASE_WORKFLOW" 'environment: release-publication'
assert_contains "$RELEASE_WORKFLOW" 'needs: candidate'
assert_contains "$RELEASE_WORKFLOW" 'artifact-ids: ${{ needs.candidate.outputs.artifact_id }}'
assert_contains "$RELEASE_WORKFLOW" '[[ "$EXPECTED_ARTIFACT_DIGEST" =~ ^[0-9a-f]{64}$ ]]'
assert_contains "$RELEASE_WORKFLOW" 'overwrite: false'
assert_contains "$RELEASE_WORKFLOW" 'bash scripts/release.sh verify-candidate "$candidate_record"'
assert_contains "$RELEASE_WORKFLOW" 'Publish already-qualified candidate'
assert_contains "$RELEASE_WORKFLOW" '[[ "$remote_tag_object" == "$SPACEO_RELEASE_TAG_OBJECT" ]]'
assert_contains "$RELEASE_WORKFLOW" 'permissions:'
assert_contains "$RELEASE_WORKFLOW" 'contents: write'

candidate_job="$(sed -n '/^  candidate:/,/^  publication:/p' "$RELEASE_WORKFLOW")"
publication_job="$(sed -n '/^  publication:/,$p' "$RELEASE_WORKFLOW")"
grep -F 'contents: read' <<<"$candidate_job" >/dev/null \
    || fail "candidate job must not receive release publication permission"
grep -F 'contents: write' <<<"$publication_job" >/dev/null \
    || fail "publication job lacks the permission required for GitHub release creation"
assert_text_excludes "$publication_job" 'secrets.'
assert_text_excludes "$publication_job" 'scripts/release.sh candidate'
assert_text_excludes "$publication_job" 'swift build'
assert_text_excludes "$publication_job" 'notarytool submit'
assert_text_excludes "$publication_job" 'codesign --sign'

# Hosted compilation must not silently fall back to Xcode 16 / Swift 6.0, which cannot parse the
# package's nonisolated(nonsending) concurrency declarations.
assert_contains "$CI_WORKFLOW" 'DEVELOPER_DIR: /Applications/Xcode_26.0.1.app/Contents/Developer'
assert_contains "$CI_WORKFLOW" 'SPACEO_REQUIRED_SWIFT_VERSION: "6.2"'
assert_contains "$CI_WORKFLOW" 'run: bash scripts/check-swift-toolchain.sh'
assert_contains "$RELEASE_WORKFLOW" 'DEVELOPER_DIR: /Applications/Xcode_26.0.1.app/Contents/Developer'
assert_contains "$TOOLCHAIN_SCRIPT" 'Swift $required_swift.x is required for nonisolated(nonsending)'

# The verifier's trust anchor must be repository-owned, not learned from the artifact.
assert_contains "$RELEASE_SCRIPT" "PUBLISHER_TEAM_ID=\"$PUBLISHER_TEAM_ID\""
assert_contains "$RELEASE_SCRIPT" 'certificate leaf[subject.OU]'
assert_contains "$RELEASE_SCRIPT" 'CHECKSUM_IDENTIFIER="dev.spaceo.release-checksum"'
assert_contains "$RELEASE_SCRIPT" 'CANDIDATE_IDENTIFIER="dev.spaceo.release-candidate"'
assert_contains "$RELEASE_SCRIPT" 'scripts/test.sh" safe'

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
if [[ "$subject" == *.candidate.txt ]]; then
    identifier="dev.spaceo.release-candidate"
elif [[ "$subject" == *.sha256 ]]; then
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

cat > "$MOCK_BIN/xcodebuild" <<'MOCK'
#!/usr/bin/env bash
printf 'Xcode %s\nBuild version fixture\n' "${FAKE_XCODE_VERSION:-26.0.1}"
MOCK

cat > "$MOCK_BIN/swift" <<'MOCK'
#!/usr/bin/env bash
printf 'Apple Swift version %s (swiftlang-fixture clang-fixture)\n' \
    "${FAKE_SWIFT_VERSION:-6.2.1}"
MOCK

cat > "$MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${TEST_GIT_COMMIT:-}" ]]; then
    exec /usr/bin/git "$@"
fi
if [[ "${1:-}" == "-C" ]]; then
    shift 2
fi
case "${1:-}" in
    show-ref)
        exit 0
        ;;
    rev-parse)
        case "${2:-}" in
            HEAD|HEAD\^\{commit\}|refs/tags/*\^\{commit\})
                printf '%s\n' "$TEST_GIT_COMMIT"
                ;;
            refs/tags/*)
                printf '%s\n' "${TEST_GIT_TAG_OBJECT:?}"
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
MOCK

chmod +x "$MOCK_BIN"/*
mkdir -p "$TEST_ROOT/Xcode.app/Contents/Developer"

PATH="$MOCK_BIN:$PATH" \
DEVELOPER_DIR="$TEST_ROOT/Xcode.app/Contents/Developer" \
SPACEO_REQUIRED_XCODE_VERSION="26.0.1" \
SPACEO_REQUIRED_SWIFT_VERSION="6.2" \
    bash "$TOOLCHAIN_SCRIPT" >/dev/null
if PATH="$MOCK_BIN:$PATH" \
   DEVELOPER_DIR="$TEST_ROOT/Xcode.app/Contents/Developer" \
   SPACEO_REQUIRED_XCODE_VERSION="26.0.1" \
   SPACEO_REQUIRED_SWIFT_VERSION="6.2" \
   FAKE_SWIFT_VERSION="6.1.2" \
       bash "$TOOLCHAIN_SCRIPT" >/dev/null 2>&1; then
    fail "an incompatible hosted Swift compiler passed the workflow toolchain assertion"
fi

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

base_name="SpaceO-$version-macOS-arm64"
candidate_record="$FIXTURE_DIR/$base_name.candidate.txt"
candidate_signature="$candidate_record.sig"
commit="$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)"
cat > "$candidate_record" <<EOF
format=spaceo-release-candidate-v1
version=$version
architecture=arm64
tag=v$version
tag_object=1111111111111111111111111111111111111111
commit=$commit
artifact=$(basename "$artifact")
artifact_sha256=$(shasum -a 256 "$artifact" | awk '{ print $1 }')
checksum=$(basename "$checksum")
checksum_sha256=$(shasum -a 256 "$checksum" | awk '{ print $1 }')
checksum_signature=$(basename "$signature")
checksum_signature_sha256=$(shasum -a 256 "$signature" | awk '{ print $1 }')
safe_verification=passed
distribution_verification=passed
workflow_repository=fixture/SpaceO
workflow_run_id=1
workflow_run_attempt=1
EOF
touch "$candidate_signature"

candidate_marker="$TEST_ROOT/candidate-executed"
PATH="$MOCK_BIN:$PATH" \
SWIFT=true \
NODE=true \
FAKE_TEAM_ID="$PUBLISHER_TEAM_ID" \
EXECUTION_MARKER="$candidate_marker" \
TEST_RELEASE_VERSION="$version" \
SPACEO_RELEASE_TAG="v$version" \
SPACEO_RELEASE_COMMIT="$commit" \
SPACEO_RELEASE_TAG_OBJECT="1111111111111111111111111111111111111111" \
SPACEO_RELEASE_WORKFLOW_REPOSITORY="fixture/SpaceO" \
SPACEO_RELEASE_WORKFLOW_RUN_ID=1 \
SPACEO_RELEASE_WORKFLOW_RUN_ATTEMPT=1 \
TEST_GIT_COMMIT="$commit" \
TEST_GIT_TAG_OBJECT="1111111111111111111111111111111111111111" \
    bash "$RELEASE_SCRIPT" verify-candidate "$candidate_record" >/dev/null
[[ -f "$candidate_marker" ]] \
    || fail "the exact retained candidate did not pass independent verification"

if PATH="$MOCK_BIN:$PATH" \
   SWIFT=true \
   NODE=true \
   FAKE_TEAM_ID="$PUBLISHER_TEAM_ID" \
   EXECUTION_MARKER="$TEST_ROOT/wrong-candidate-executed" \
   TEST_RELEASE_VERSION="$version" \
   SPACEO_RELEASE_TAG="v$version" \
   SPACEO_RELEASE_COMMIT="2222222222222222222222222222222222222222" \
   TEST_GIT_COMMIT="$commit" \
   TEST_GIT_TAG_OBJECT="1111111111111111111111111111111111111111" \
       bash "$RELEASE_SCRIPT" verify-candidate "$candidate_record" >/dev/null 2>&1; then
    fail "candidate verification accepted provenance for a different release commit"
fi

echo "release security policy tests passed"
