# Setup guide

SpaceO is a preview; the current release is [1.1.1](https://github.com/ParthJadhav/SpaceO/releases/tag/v1.1.1).
This guide takes you from a source build to a session self-test and MCP configuration. If a step
fails, see [Troubleshooting](TROUBLESHOOTING.md).

SpaceO keeps agent windows on another display, but apps still run as your macOS user with that
user's files and app sessions. Use a separate login or VM for untrusted workloads.

## 1. Check what you need

- macOS 14 or later on Apple Silicon. Intel is not supported.
- **SIP stays on.** SpaceO never needs it off.
- To build from source: Xcode 26.0.1 with Swift 6.2, and Node.js for the MCP smoke test.
- An app that will run `spaceo` (a terminal, Claude Code, Cursor, Codex, or Claude Desktop).
  macOS can attribute permission requests to that launcher; verify the actual caller and daemon
  with `doctor` rather than assuming a visible enabled switch proves access.

## 2. Install `spaceo`

**From a release** — follow [Installing a SpaceO release](INSTALL.md). It verifies the
publisher signature and checksum before you run anything.

**From source:**

```bash
git clone https://github.com/ParthJadhav/SpaceO.git
cd SpaceO
make install          # builds and installs to ~/.local/bin/spaceo
```

Make sure `~/.local/bin` is on your `PATH`, or use the full path everywhere:

```bash
export PATH="$HOME/.local/bin:$PATH"
spaceo version
```

Set `PREFIX` to install somewhere else: `make install PREFIX=/opt/spaceo`.

`make install` prints the version it installed and, when a daemon is already running a different
version, says so (`installed 1.1.1 over 1.0.0; the running daemon is still 1.0.0 → spaceo daemon
restart --operator`). It never restarts the daemon for you.

Shell completion is generated from the command table:

```bash
eval "$(spaceo completions zsh)"     # add this line to ~/.zshrc; bash works the same way
spaceo completions fish | source     # or save it as ~/.config/fish/completions/spaceo.fish
```

### Rebuilding locally without changing signing identity

Ordinary `make build`, `make release`, and `make install` leave the CLI ad-hoc signed. Its
code identity can change when the executable changes, so direct privacy grants may need renewal.
If you have a Developer ID Application certificate and its private key installed, use:

```bash
make signed
.build/signed/spaceo doctor
```

This builds certificate-signed copies at `.build/signed/spaceo` and
`.build/signed/SpaceO Viewer.app`. Use those same absolute paths in your launcher/MCP configuration
and rebuild with `make signed`. The command selects the sole installed Developer ID Application
identity; if there are several, select one with `SPACEO_CODESIGN_IDENTITY`. It refuses ad-hoc
fallback and refuses to replace an existing signed CLI with a different code identity.

The initial permission grant is still required. Certificate-backed identity improves permission
continuity; it does not override a denial or guarantee access through every launcher. These local
artifacts are not notarized or release-qualified. This command does not install an app, restart a
daemon, or publish a release. Deleting `.build` removes these local artifacts.

## 3. Grant permissions

Open **System Settings → Privacy & Security** and enable, for the app that runs `spaceo`:

| Permission | Needed for | Without it |
|---|---|---|
| Accessibility | window placement, clicks, typing, keys | every input command fails |
| Screen & System Audio Recording | screenshots and the Viewer stream | screenshots fail; input still works |

Start with the **host app** — Terminal, iTerm, Claude Code's terminal, Cursor, Claude Desktop —
when macOS attributes the request to it. You do not have to guess which one: `spaceo doctor`
prints `caller attributed to: Cursor (/Applications/Cursor.app)`, every permission error names
the same app, and on a terminal `spaceo setup` opens the exact Settings pane and waits up to two
minutes for the grant to land before continuing. If the exact executable appears separately,
grant that entry as well. A daemon launched through another app may have different effective
permissions; check both caller and daemon rows in `doctor`.

To give the daemon a permanent identity of its own instead of inheriting whichever client
started it, install it as a LaunchAgent from a stably signed build (`make signed`):

```bash
spaceo daemon install        # writes ~/Library/LaunchAgents/com.spaceo.daemon.plist
spaceo daemon status
```

Grant Accessibility and Screen Recording to that daemon once; they survive client restarts, and
MCP clients stop spawning their own daemons. Ad-hoc signed builds are refused because their
identity changes on every build.

`SpaceO Viewer.app` needs both permissions itself.

## 4. Check the host, then run setup

Start with the read-only check:

```bash
spaceo doctor
```

For a report and MCP configuration without permission prompts, daemon startup, or a test display:

```bash
spaceo setup --no-prompt --no-self-test
```

When the desktop is idle, run the live session self-test:

```bash
spaceo setup
```

Setup checks runtime APIs and caller permissions, starts a daemon if needed, and verifies the
running daemon's build and its own permissions. A stale daemon is reported with restart guidance;
setup does not stop other controllers' work automatically. It then creates a uniquely named
session, validates its PNG capture, checks the teardown response, and prints client configuration.
Its temporary capture is kept in a private directory and removed after the test.

A passing self-test verifies session creation, capture, and session teardown. It does not launch
an app or prove input delivery, cross-session isolation, or full display retirement. Empty displays
retire after the daemon's 15-second reuse grace. `spaceo pool` shows current usage.

A good run looks like this:

```
SpaceO setup
  ok   runtime apis        every private display, Space, and input symbol SpaceO needs is present
  ok   accessibility       granted for this process; required for window placement and AX input
  ok   screen recording    granted for this process; required for screenshots
  ok   daemon              reachable at /var/folders/.../spaceo-501.sock
  ok   daemon build        matches this CLI
  ok   daemon input        driving prerequisites available in the daemon
  ok   daemon capture      capture prerequisites available in the daemon
  ok   self-test           created and captured a session; session teardown confirmed. Empty displays retire after the daemon's reuse grace.

Register SpaceO with your MCP client:
  ...
```

Every `MISS` line comes with the fix under it. Fix them, then run `spaceo setup` again.
Use `--no-self-test` to skip the live round trip, or `--json` for machine-readable output. Skipped
checks are listed explicitly. If cleanup cannot be confirmed, setup fails and names its own test
session with a targeted recovery command.

## 5. Register with your MCP client

Let setup write it for you:

```bash
spaceo setup --client claude-code      # runs `claude mcp add -s user spaceo -- <abs path> mcp`
spaceo setup --client codex            # merges into ~/.codex/config.toml
spaceo setup --client cursor           # merges into ~/.cursor/mcp.json
spaceo setup --client claude-desktop   # merges into claude_desktop_config.json
```

It shows a diff, asks before writing (`--yes` skips the prompt, `--print` only prints), always
writes an absolute path, and keeps every other server entry. For Claude Code it finds `claude` on
your `PATH` (npm, nvm, and Homebrew installs all work), registers at user scope so the entry is
not tied to the directory you ran it from, and, when a `spaceo` entry already exists, shows and
runs `claude mcp remove -s user spaceo` before the add. It warns when the path it would register
is inside a `.build/` directory: the next build or clean replaces that file, so run
`make install` and register `~/.local/bin/spaceo` instead. Or copy the block `spaceo setup`
printed for your client, or use these (replace `you` with your macOS account name — not every
client expands `~`):

**Claude Code**
```bash
claude mcp add -s user spaceo -- "$HOME/.local/bin/spaceo" mcp
```

**Codex** (`~/.codex/config.toml`)
```toml
[mcp_servers.spaceo]
command = "/Users/you/.local/bin/spaceo"
args = ["mcp"]
```

**Cursor / Claude Desktop** (`mcp.json` / `claude_desktop_config.json`)
```json
{ "mcpServers": { "spaceo": {
  "command": "/Users/you/.local/bin/spaceo", "args": ["mcp"]
} } }
```

Restart the client. The MCP server starts the shared daemon on demand, so you do not need to run
`spaceo daemon` by hand for MCP use. `spaceo doctor` lists every client's registration under
**MCP clients**, with the version of the binary each one launches.

## 6. Try it

On an idle desktop, the self-contained demo launches apps, sends input, and attempts cleanup.
It needs no daemon:

```bash
spaceo demo
```

Or drive an app by hand:

```bash
spaceo daemon &
eval "$(spaceo session create --session try --export)"   # sets SPACEO_SESSION and SPACEO_LEASE
spaceo run TextEdit
spaceo ax                                  # indexed elements
spaceo click --element 0
spaceo type "hello"
spaceo screenshot -o /tmp/try.png
spaceo session destroy
spaceo daemon stop
```

`SPACEO_SESSION` and `SPACEO_LEASE` are defaults for `--session` and `--lease`; a flag always
wins. Without `--export`, `session create` prints the lease for you to pass as `--lease UUID`.
Every command's options and examples are one `spaceo help <command>` away.

Check the reported input outcome and isolation coverage. Stop if a covered check reports a
breach. `partial` means some required state could not be observed; it is not an isolation pass.

## 7. Optional: the Viewer

`SpaceO Viewer` shows every agent display live and lets you take control of one with your own
mouse and keyboard.

```bash
make viewer
open ".build/SpaceO Viewer.app"
```

Or install the signed local build in `/Applications` and open it:

```bash
make install-viewer
```

Grant it Accessibility and Screen Recording when the in-app banner asks. **Control-Command-Escape**
always hands control back.

## 8. Optional: pack more agents per display

Set these in the MCP client's `env` block (or the shell that starts the daemon). The daemon reads
them at startup:

```json
"env": { "SPACEO_SESSIONS_PER_DISPLAY": "4", "SPACEO_DISPLAY_SIZE": "2560x1440" }
```

`spaceo pool` shows current usage.

## Next

- [Keeping SpaceO up to date](UPDATING.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Session ownership and recovery](SESSION_RECOVERY.md) — leases, restarts, cleanup
