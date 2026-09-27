#!/usr/bin/env bash
# SpaceO installer: downloads the latest signed release, verifies it, installs it, and connects
# the MCP clients it finds.
#
#   curl -fsSL https://raw.githubusercontent.com/ParthJadhav/SpaceO/main/install.sh | bash
#
# Every download is authenticated before anything from it runs: the checksum's detached Developer
# ID signature must come from SpaceO's Team ID, the disk image must match that checksum and pass
# Gatekeeper, and both payloads must carry SpaceO's exact designated requirement. This is the
# procedure in docs/INSTALL.md, automated. Nothing needs administrator rights.
set -euo pipefail

# The whole script is one function called on the last line, so a truncated download runs nothing.
main() {
    local repository="ParthJadhav/SpaceO"
    local team_id="75LRT8TRQY"
    local bin_dir="${SPACEO_BIN_DIR:-$HOME/.local/bin}"
    local app_dir="${SPACEO_APP_DIR:-$HOME/Applications}"
    local version="" assume_yes=0 run_setup=1 connect_clients=1 install_viewer=1 modify_path=1
    local uninstall=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) assume_yes=1 ;;
            --no-setup) run_setup=0 ;;
            --no-clients) connect_clients=0 ;;
            --no-viewer) install_viewer=0 ;;
            --no-modify-path) modify_path=0 ;;
            --version)
                [[ $# -ge 2 ]] || die "--version needs a value, e.g. --version 1.0.0"
                version="${2#v}"; shift ;;
            --version=*) version="${1#--version=}"; version="${version#v}" ;;
            --uninstall) uninstall=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    # `curl | bash` gives this script the pipe as stdin; questions go to the terminal instead.
    local interactive=0
    if [[ -t 1 ]] && (exec </dev/tty) 2>/dev/null; then interactive=1; fi

    if [[ "$uninstall" == 1 ]]; then
        uninstall_spaceo "$bin_dir" "$app_dir"
        return
    fi

    header "Installing SpaceO"
    check_host
    local tool
    for tool in curl codesign shasum spctl hdiutil ditto; do
        command -v "$tool" >/dev/null 2>&1 || die "required command not found: $tool"
    done

    if [[ -z "$version" ]]; then
        version="$(latest_version "$repository")"
    fi
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a release version: $version"

    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/spaceo-install.XXXXXX")"
    local mount="$work/mount"
    # Detach before deleting: removing a mounted image's directory would fail and leak the mount.
    # shellcheck disable=SC2064 # expand now; these locals are gone when the trap runs
    trap "hdiutil detach '$mount' -quiet >/dev/null 2>&1 || true; rm -rf '$work'" EXIT

    local name="SpaceO-$version-macOS-arm64"
    local base="https://github.com/$repository/releases/download/v$version"
    step "Downloading SpaceO $version"
    local file
    for file in "$name.dmg" "$name.sha256" "$name.sha256.sig"; do
        curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$work/$file" "$base/$file" \
            || die "could not download $base/$file"
    done

    step "Verifying publisher signature, checksum, and notarization"
    codesign --verify --detached "$work/$name.sha256.sig" --strict \
        -R "=anchor apple generic and certificate leaf[subject.OU] = \"$team_id\" and identifier \"dev.spaceo.release-checksum\"" \
        "$work/$name.sha256" >/dev/null 2>&1 \
        || die "the checksum is not signed by SpaceO's publisher ($team_id); not installing"
    (cd "$work" && shasum -a 256 -c "$name.sha256" >/dev/null 2>&1) \
        || die "the disk image does not match its signed checksum; not installing"
    spctl --assess --type open --context context:primary-signature "$work/$name.dmg" >/dev/null 2>&1 \
        || die "Gatekeeper rejected the disk image; not installing"

    mkdir -p "$mount"
    hdiutil attach "$work/$name.dmg" -readonly -nobrowse -noautoopen -mountpoint "$mount" -quiet \
        || die "could not mount the disk image"
    codesign --verify --strict \
        -R "=anchor apple generic and certificate leaf[subject.OU] = \"$team_id\" and identifier \"dev.spaceo.cli\"" \
        "$mount/spaceo" >/dev/null 2>&1 \
        || die "the spaceo CLI is not signed by SpaceO's publisher; not installing"
    if [[ "$install_viewer" == 1 ]]; then
        codesign --verify --deep --strict \
            -R "=anchor apple generic and certificate leaf[subject.OU] = \"$team_id\" and identifier \"dev.spaceo.viewer\"" \
            "$mount/SpaceO Viewer.app" >/dev/null 2>&1 \
            || die "SpaceO Viewer is not signed by SpaceO's publisher; not installing"
        spctl --assess --type execute "$mount/SpaceO Viewer.app" >/dev/null 2>&1 \
            || die "Gatekeeper rejected SpaceO Viewer; not installing"
    fi
    ok "signed by $team_id, notarized, checksum matches"

    step "Installing"
    local cli="$bin_dir/spaceo" previous=""
    if [[ -x "$cli" ]]; then previous="$("$cli" version 2>/dev/null | awk '{print $2}')" || true; fi
    mkdir -p "$bin_dir"
    # Copy then rename: a running daemon keeps its old inode instead of having its code rewritten.
    install -m 755 "$mount/spaceo" "$bin_dir/.spaceo.new"
    mv -f "$bin_dir/.spaceo.new" "$cli"
    ok "spaceo $version → $cli${previous:+ (was $previous)}"

    if [[ "$install_viewer" == 1 ]]; then
        # Update a Viewer already installed for all users in place instead of adding a second copy.
        if [[ -z "${SPACEO_APP_DIR:-}" && -d "/Applications/SpaceO Viewer.app" && -w "/Applications" ]]; then
            app_dir="/Applications"
        fi
        mkdir -p "$app_dir"
        local viewer="$app_dir/SpaceO Viewer.app" staged="$app_dir/.SpaceO Viewer.app.new"
        rm -rf "$staged"
        ditto "$mount/SpaceO Viewer.app" "$staged"
        rm -rf "$viewer"
        mv "$staged" "$viewer"
        ok "SpaceO Viewer → $viewer"
    fi
    hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true

    if [[ "$modify_path" == 1 ]]; then add_to_path "$bin_dir"; fi
    report_stale_daemon "$cli" "$version"

    if [[ "$connect_clients" == 1 ]]; then
        connect_mcp_clients "$cli" "$assume_yes" "$interactive" "$work/client.log"
    fi

    if [[ "$run_setup" == 1 && "$interactive" == 1 ]] \
        && ask "Grant permissions and run a quick self-test now?" Y "$assume_yes" "$interactive"; then
        header "Guided setup"
        note "SpaceO needs Accessibility and Screen Recording. Setup opens the right Settings"
        note "pane and waits for you to switch them on, then briefly creates a virtual display."
        echo
        "$cli" setup </dev/tty || warn "setup did not finish; run \`spaceo setup\` again when ready"
    else
        run_setup=0
    fi

    header "SpaceO $version is installed"
    if [[ "$run_setup" == 0 ]]; then
        note "Next: run \`spaceo setup\` to grant permissions and self-test."
    fi
    note "Then ask your agent: \"Open TextEdit in SpaceO, write a short note, and show me a screenshot.\""
    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        note "Open a new terminal (or run: export PATH=\"$bin_dir:\$PATH\") to use \`spaceo\`."
    fi
    note "Docs: https://github.com/$repository#get-started · Uninstall: re-run with --uninstall"
}

# MARK: - host and release

check_host() {
    [[ "$(uname -s)" == Darwin ]] || die "SpaceO runs on macOS only"
    # `uname -m` reports x86_64 under Rosetta; the hardware flag does not.
    [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]] || die "SpaceO requires Apple Silicon"
    local release major
    release="$(sw_vers -productVersion)"
    major="${release%%.*}"
    [[ "$major" =~ ^[0-9]+$ && "$major" -ge 14 ]] || die "SpaceO requires macOS 14 or later (found $release)"
}

# The /releases/latest page redirects to /releases/tag/vX.Y.Z; no API token or rate limit needed.
latest_version() {
    local url tag
    url="$(curl -fsSL --proto '=https' --tlsv1.2 -o /dev/null -w '%{url_effective}' \
        "https://github.com/$1/releases/latest")" || die "could not reach GitHub to find the latest release"
    tag="${url##*/}"
    [[ "$tag" == v* ]] || die "could not determine the latest release (got $url)"
    printf '%s\n' "${tag#v}"
}

# MARK: - PATH

add_to_path() {
    local dir="$1" profile line
    [[ ":$PATH:" != *":$dir:"* ]] || return 0
    case "$(basename "${SHELL:-/bin/zsh}")" in
        zsh)  profile="${ZDOTDIR:-$HOME}/.zshrc"; line="export PATH=\"$dir:\$PATH\"" ;;
        bash) profile="$HOME/.bash_profile";      line="export PATH=\"$dir:\$PATH\"" ;;
        fish) profile="$HOME/.config/fish/config.fish"; line="fish_add_path \"$dir\"" ;;
        *) warn "add $dir to your PATH to run \`spaceo\` by name"; return 0 ;;
    esac
    if [[ -f "$profile" ]] && grep -Fqx "$line" "$profile"; then return 0; fi
    mkdir -p "$(dirname "$profile")"
    printf '\n# Added by the SpaceO installer\n%s\n' "$line" >> "$profile"
    ok "added $dir to PATH in $profile"
}

# MARK: - daemon

# Mirrors `make install`: say when a running daemon is a different build, never restart it, since
# other agents' sessions may be live on it.
report_stale_daemon() {
    local cli="$1" version="$2" json running
    json="$("$cli" daemon wait --timeout 1 --json 2>/dev/null)" || return 0
    running="$(printf '%s' "$json" | sed -n 's/.*"daemon":{[^}]*"version":"\([^"]*\)".*/\1/p')"
    if [[ -n "$running" && "$running" != "$version" ]]; then
        warn "a SpaceO $running daemon is still running; restart it when its sessions finish:"
        note "    spaceo daemon restart --operator"
    fi
}

# MARK: - MCP clients

# Prints `id|display name` for each MCP client that looks installed.
detect_clients() {
    if command -v claude >/dev/null 2>&1 || [[ -e "$HOME/.claude.json" || -x "$HOME/.claude/local/claude" ]]; then
        echo "claude-code|Claude Code"
    fi
    if command -v codex >/dev/null 2>&1 || [[ -d "$HOME/.codex" ]]; then
        echo "codex|Codex"
    fi
    if [[ -d "$HOME/.cursor" || -d "/Applications/Cursor.app" || -d "$HOME/Applications/Cursor.app" ]]; then
        echo "cursor|Cursor"
    fi
    if [[ -d "$HOME/Library/Application Support/Claude" || -d "/Applications/Claude.app" \
          || -d "$HOME/Applications/Claude.app" ]]; then
        echo "claude-desktop|Claude Desktop"
    fi
}

connect_mcp_clients() {
    local cli="$1" assume_yes="$2" interactive="$3" log="$4" found entry id label
    found="$(detect_clients)"
    if [[ -z "$found" ]]; then
        note "No MCP clients found. Connect one later: spaceo setup --client claude-code|codex|cursor|claude-desktop"
        return 0
    fi
    header "Connecting your agents"
    while IFS= read -r entry; do
        id="${entry%%|*}"; label="${entry#*|}"
        if ! ask "Connect SpaceO to $label?" Y "$assume_yes" "$interactive"; then
            note "  skipped; later: spaceo setup --client $id"
            continue
        fi
        # setup edits only the `spaceo` entry and keeps every other server. Its own prompt cannot
        # read the piped stdin, so the answer given here is passed on as --yes.
        if "$cli" setup --client "$id" --yes </dev/null >/dev/null 2>"$log"; then
            ok "$label connected (restart it to load SpaceO)"
        else
            warn "could not connect $label: $(tail -n 3 "$log" | tr '\n' ' ')"
            note "  retry with: spaceo setup --client $id"
        fi
    done <<< "$found"
}

# MARK: - uninstall

uninstall_spaceo() {
    local bin_dir="$1" app_dir="$2" cli="$1/spaceo" removed=0 dir
    header "Uninstalling SpaceO"
    if [[ -x "$cli" ]]; then
        # A LaunchAgent would restart the daemon; remove it before stopping.
        "$cli" daemon uninstall >/dev/null 2>&1 || true
        "$cli" daemon stop >/dev/null 2>&1 || true
        rm -f "$cli"; ok "removed $cli"; removed=1
    fi
    for dir in "$app_dir" "/Applications"; do
        [[ -d "$dir/SpaceO Viewer.app" ]] || continue
        if rm -rf "$dir/SpaceO Viewer.app" 2>/dev/null; then
            ok "removed $dir/SpaceO Viewer.app"; removed=1
        else
            warn "could not remove $dir/SpaceO Viewer.app; move it to the Trash"
        fi
    done
    [[ "$removed" == 1 ]] || note "SpaceO was not found in $bin_dir or $app_dir."
    note "MCP client entries named \`spaceo\` were left in place; remove them in each client"
    note "(Claude Code: claude mcp remove -s user spaceo)."
}

# MARK: - output

usage() {
    cat <<'USAGE'
Install SpaceO:
  curl -fsSL https://raw.githubusercontent.com/ParthJadhav/SpaceO/main/install.sh | bash
Pass options with `| bash -s -- [options]`:

  --yes             accept every prompt (connect all detected clients, run guided setup)
  --no-setup        install and connect clients, but do not run `spaceo setup`
  --no-clients      do not register SpaceO with any MCP client
  --no-viewer       install only the CLI
  --no-modify-path  do not add the install directory to your shell profile
  --version X.Y.Z   install that release instead of the latest
  --uninstall       stop the daemon and remove the CLI and Viewer

Environment: SPACEO_BIN_DIR (default ~/.local/bin), SPACEO_APP_DIR (default ~/Applications)
USAGE
}

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi

header() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
step()   { printf '%s→%s %s\n' "$DIM" "$RESET" "$*"; }
ok()     { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()   { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
note()   { printf '%s\n' "$*"; }
die()    { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ask QUESTION DEFAULT(Y|N) ASSUME_YES INTERACTIVE → status 0 for yes. Without a terminal the
# default applies.
ask() {
    local question="$1" default="$2" assume_yes="$3" interactive="$4" reply="" hint="[Y/n]"
    [[ "$assume_yes" != 1 ]] || return 0
    if [[ "$interactive" != 1 ]]; then [[ "$default" == Y ]]; return; fi
    [[ "$default" == Y ]] || hint="[y/N]"
    printf '%s %s ' "$question" "$hint" >/dev/tty
    # End of input (Ctrl-D, a closed terminal) is not consent.
    IFS= read -r reply </dev/tty || { printf '\n' >/dev/tty; return 1; }
    case "$reply" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        *) [[ "$default" == Y ]] ;;
    esac
}

main "$@"
