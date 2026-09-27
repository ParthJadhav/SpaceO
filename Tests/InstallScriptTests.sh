#!/usr/bin/env bash
# Exercises install.sh against a fake release: no network, no real mount, no daemon, and a fake
# HOME so no real shell profile or MCP client configuration is touched.
# shellcheck disable=SC2016 # mock bodies are single-quoted on purpose; they expand when run
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$REPOSITORY_ROOT/install.sh"

fail() {
    echo "install script test failed: $*" >&2
    exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaceo-install-script-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
MOCK_BIN="$TEST_ROOT/bin"
RELEASE="$TEST_ROOT/release"
PAYLOAD="$TEST_ROOT/payload"
mkdir -p "$MOCK_BIN" "$RELEASE" "$PAYLOAD/SpaceO Viewer.app/Contents"
export SPACEO_TEST_LOG="$TEST_ROOT/spaceo-calls.log"
export SPACEO_TEST_RELEASE="$RELEASE" SPACEO_TEST_PAYLOAD="$PAYLOAD"

# The payload the fake disk image "contains". The CLI records every invocation. A running daemon
# and an installed LaunchAgent are marker files; only an operator-scoped stop ends the daemon,
# like the real one, and a LaunchAgent keeps restarting it.
export SPACEO_TEST_DAEMON="$TEST_ROOT/daemon-running" SPACEO_TEST_AGENT="$TEST_ROOT/agent-installed"
cat > "$PAYLOAD/spaceo" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SPACEO_TEST_LOG"
case "$1 ${2:-}" in
    "version "*) echo "spaceo 9.9.9" ;;
    "daemon wait") [[ -e "$SPACEO_TEST_DAEMON" ]] ;;
    "daemon status")
        if [[ -e "$SPACEO_TEST_AGENT" ]]; then echo '{"installed":true}'; else echo '{"installed":false}'; fi ;;
    "daemon uninstall") [[ "$*" == *--yes* ]] || exit 2; rm -f "$SPACEO_TEST_AGENT" ;;
    "daemon stop")
        [[ "$*" == *--operator* ]] || exit 4
        [[ -e "$SPACEO_TEST_AGENT" ]] || rm -f "$SPACEO_TEST_DAEMON" ;;
    "setup "*) exit 0 ;;
esac
MOCK
chmod 755 "$PAYLOAD/spaceo"
printf 'viewer\n' > "$PAYLOAD/SpaceO Viewer.app/Contents/marker"

NAME="SpaceO-9.9.9-macOS-arm64"
printf 'disk image\n' > "$RELEASE/$NAME.dmg"
(cd "$RELEASE" && shasum -a 256 "$NAME.dmg" > "$NAME.sha256")
printf 'signature\n' > "$RELEASE/$NAME.sha256.sig"

mock() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$MOCK_BIN/$1"; chmod 755 "$MOCK_BIN/$1"; }
mock uname 'echo Darwin'
mock sysctl 'echo 1'
mock sw_vers 'echo "${SPACEO_TEST_MACOS:-15.1}"'
mock spctl 'exit 0'
mock curl '
out=""; url=""; effective=0
while [[ $# -gt 0 ]]; do
    case "$1" in -o) out="$2"; shift ;; -w) effective=1; shift ;; --proto|--retry) shift ;; -*) ;; *) url="$1" ;; esac
    shift
done
if [[ "$effective" == 1 ]]; then echo "https://github.com/ParthJadhav/SpaceO/releases/tag/v9.9.9"; exit 0; fi
[[ -f "$SPACEO_TEST_RELEASE/${url##*/}" ]] || exit 22
cp "$SPACEO_TEST_RELEASE/${url##*/}" "$out"'
# A detached-signature check fails when the test asks for an untrusted publisher.
mock codesign '
for argument in "$@"; do
    [[ "$argument" == --detached && -n "${SPACEO_TEST_BAD_SIGNATURE:-}" ]] && exit 1
done
exit 0'
mock hdiutil '
case "$1" in
    attach) while [[ $# -gt 0 ]]; do [[ "$1" == -mountpoint ]] && mount="$2"; shift; done
            cp -R "$SPACEO_TEST_PAYLOAD/." "$mount/" ;;
    detach) exit 0 ;;
esac'

run_installer() {
    local home="$1"; shift
    mkdir -p "$home"
    env -i PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$home" SHELL=/bin/zsh \
        TMPDIR="$TEST_ROOT" SPACEO_TEST_LOG="$SPACEO_TEST_LOG" SPACEO_TEST_RELEASE="$RELEASE" \
        SPACEO_TEST_PAYLOAD="$PAYLOAD" SPACEO_TEST_BAD_SIGNATURE="${SPACEO_TEST_BAD_SIGNATURE:-}" \
        SPACEO_TEST_DAEMON="$SPACEO_TEST_DAEMON" SPACEO_TEST_AGENT="$SPACEO_TEST_AGENT" \
        SPACEO_TEST_MACOS="${SPACEO_TEST_MACOS:-}" SPACEO_APP_DIR="$home/Applications" \
        bash "$INSTALL_SCRIPT" "$@" < /dev/null
}

# 1. Happy path: installs both payloads, edits PATH once, connects the detected client, and does
#    not run guided setup without a terminal.
HOME_A="$TEST_ROOT/home-a"
mkdir -p "$HOME_A/.codex"
output="$(run_installer "$HOME_A" 2>&1)" || fail "installer failed: $output"
[[ -x "$HOME_A/.local/bin/spaceo" ]] || fail "CLI was not installed"
[[ -f "$HOME_A/Applications/SpaceO Viewer.app/Contents/marker" ]] || fail "Viewer was not installed"
[[ ! -e "$HOME_A/.local/bin/.spaceo.new" ]] || fail "staged CLI was left behind"
grep -Fqx 'export PATH="'"$HOME_A"'/.local/bin:$PATH"' "$HOME_A/.zshrc" || fail "PATH was not added to .zshrc"
grep -Fqx 'setup --client codex --yes' "$SPACEO_TEST_LOG" || fail "Codex was not connected: $(cat "$SPACEO_TEST_LOG")"
grep -Fqx 'setup' "$SPACEO_TEST_LOG" && fail "guided setup ran without a terminal"
[[ "$output" == *"Next: run \`spaceo setup\`"* ]] || fail "missing next step: $output"

# 2. Re-running is an upgrade: the PATH line is not duplicated and the old version is reported.
output="$(run_installer "$HOME_A" 2>&1)" || fail "re-run failed: $output"
[[ "$(grep -c 'Added by the SpaceO installer' "$HOME_A/.zshrc")" == 1 ]] || fail "PATH line duplicated"
[[ "$output" == *"(was 9.9.9)"* ]] || fail "previous version not reported: $output"

# 3. Opt-outs are honored.
HOME_B="$TEST_ROOT/home-b"
mkdir -p "$HOME_B/.codex"
: > "$SPACEO_TEST_LOG"
run_installer "$HOME_B" --no-clients --no-viewer --no-modify-path --version v9.9.9 >/dev/null 2>&1 \
    || fail "installer with opt-outs failed"
[[ ! -e "$HOME_B/Applications/SpaceO Viewer.app" ]] || fail "--no-viewer installed the Viewer"
[[ ! -e "$HOME_B/.zshrc" ]] || fail "--no-modify-path edited the profile"
grep -Fq 'setup --client' "$SPACEO_TEST_LOG" && fail "--no-clients connected a client"

# 4. An untrusted checksum signature installs nothing.
HOME_C="$TEST_ROOT/home-c"
if output="$(SPACEO_TEST_BAD_SIGNATURE=1 run_installer "$HOME_C" 2>&1)"; then fail "accepted a bad signature"; fi
[[ "$output" == *"not signed by SpaceO's publisher"* ]] || fail "wrong refusal: $output"
[[ ! -e "$HOME_C/.local/bin/spaceo" ]] || fail "installed after a bad signature"

# 5. A disk image that does not match its checksum installs nothing.
cp "$RELEASE/$NAME.dmg" "$TEST_ROOT/good.dmg"
printf 'tampered\n' > "$RELEASE/$NAME.dmg"
if output="$(run_installer "$HOME_C" 2>&1)"; then fail "accepted a tampered image"; fi
[[ "$output" == *"does not match its signed checksum"* ]] || fail "wrong refusal: $output"
[[ ! -e "$HOME_C/.local/bin/spaceo" ]] || fail "installed a tampered image"
cp "$TEST_ROOT/good.dmg" "$RELEASE/$NAME.dmg"

# 6. Unsupported macOS is refused before any download.
if output="$(SPACEO_TEST_MACOS=13.6 run_installer "$HOME_C" 2>&1)"; then fail "accepted macOS 13"; fi
[[ "$output" == *"requires macOS 14 or later"* ]] || fail "wrong refusal: $output"

# 7. Uninstall stops the daemon before removing the CLI and Viewer.
: > "$SPACEO_TEST_LOG"
run_installer "$HOME_A" --uninstall >/dev/null 2>&1 || fail "uninstall failed"
grep -Fq 'daemon stop' "$SPACEO_TEST_LOG" && fail "uninstall stopped a daemon that was not running"
[[ ! -e "$HOME_A/.local/bin/spaceo" ]] || fail "uninstall left the CLI"
[[ ! -e "$HOME_A/Applications/SpaceO Viewer.app" ]] || fail "uninstall left the Viewer"

# 8. With a daemon running, uninstall without --yes and without a terminal keeps everything.
run_installer "$HOME_A" --no-clients >/dev/null 2>&1 || fail "reinstall failed"
touch "$SPACEO_TEST_DAEMON" "$SPACEO_TEST_AGENT"
if output="$(run_installer "$HOME_A" --uninstall 2>&1)"; then fail "uninstall ended live sessions without consent"; fi
[[ "$output" == *"daemon is still running"* ]] || fail "wrong refusal: $output"
[[ -x "$HOME_A/.local/bin/spaceo" ]] || fail "CLI removed while its daemon still runs"
[[ -e "$SPACEO_TEST_DAEMON" ]] || fail "daemon stopped without consent"

# 9. With --yes: the LaunchAgent goes first, the stop is operator-scoped, and only then the CLI.
: > "$SPACEO_TEST_LOG"
run_installer "$HOME_A" --uninstall --yes >/dev/null 2>&1 || fail "uninstall --yes failed"
[[ ! -e "$SPACEO_TEST_AGENT" && ! -e "$SPACEO_TEST_DAEMON" ]] || fail "LaunchAgent or daemon survived"
grep -Fqx 'daemon stop --operator' "$SPACEO_TEST_LOG" || fail "stop was not operator-scoped"
[[ ! -e "$HOME_A/.local/bin/spaceo" ]] || fail "uninstall --yes left the CLI"

# 10. A Viewer set aside by an interrupted upgrade is restored, then replaced.
HOME_D="$TEST_ROOT/home-d"
mkdir -p "$HOME_D/Applications/.SpaceO Viewer.app.old/Contents"
run_installer "$HOME_D" --no-clients >/dev/null 2>&1 || fail "install over an interrupted upgrade failed"
[[ -f "$HOME_D/Applications/SpaceO Viewer.app/Contents/marker" ]] || fail "Viewer not installed"
[[ ! -e "$HOME_D/Applications/.SpaceO Viewer.app.old" ]] || fail "set-aside Viewer left behind"

# No mount point or work directory may outlive a run.
leftovers="$(find "$TEST_ROOT" -maxdepth 1 -name 'spaceo-install.*')"
[[ -z "$leftovers" ]] || fail "work directories left behind: $leftovers"

echo "install script tests passed"
