# Keeping SpaceO up to date

A quick way to confirm that the CLI, daemon, Viewer, MCP clients, and permissions all agree, and
how to upgrade when they do not.

## Two-minute check

```bash
spaceo version          # the CLI you have
spaceo doctor           # the daemon, MCP clients, and Viewer, and whether each matches
```

`doctor` groups its report into Host, Permissions, Daemon, MCP clients, Viewer, and Disk. Look
for:

| Section / line | Want | If not |
|---|---|---|
| Host `cli version` | the version you expect, at the path you expect | you are running a different copy; check `which spaceo` |
| Daemon `daemon matches CLI` | `yes` | `NO` or `unknown`: the daemon is still running old code. Restart it (below). |
| Daemon `daemon version` | same as `spaceo version` | same fix |
| Daemon `daemon running` | `yes` or `no` | `yes (did not answer within 2s — busy?)`: a daemon is listening but busy; retry doctor before acting |
| MCP clients | every entry `matches this CLI` | `STALE`: that client launches an older binary; follow the `next:` line, then restart the client |
| Permissions `accessibility` / `screen-recording` | `ok` | re-grant; see [Setup step 3](SETUP.md#3-grant-permissions) |
| Permissions `daemon can drive` | `yes` | the daemon's host app lacks Accessibility; grant it and restart |
| Viewer `installed` | same version as the CLI | rebuild or reinstall the Viewer |
| Host `SpaceO display ids` | `none` when idle | leftover displays; see [Troubleshooting](TROUBLESHOOTING.md#displays) |

Any CLI command also warns once on stderr when the daemon that answered is a different version
(`warning: the running daemon is 1.0.0 (pid N); this CLI is 1.1.1 — run spaceo daemon restart
--operator`), and a command the old daemon does not know fails with `daemon_outdated` (exit 3)
instead of a bare `unknown command`.

`doctor` compares the daemon's Mach-O build UUID with the CLI's, so a re-signed Viewer helper
still counts as a match. `unknown` means the daemon is older than this check.

## Is a newer version available?

- **Releases:** check the [GitHub releases page](https://github.com/ParthJadhav/SpaceO/releases).
  No signed public release is published yet; `VERSION` on `main` is the planned number, not a
  download.
- **Source builds:** compare your checkout with `main`:

  ```bash
  git fetch origin
  git log --oneline HEAD..origin/main     # empty means you are current
  cat VERSION
  ```

- **Changelog:** [CHANGELOG.md](../CHANGELOG.md) lists what changed, including under
  `[Unreleased]` for builds from `main`.

## Restart the daemon after any upgrade

Replacing the file on disk does not replace the code already loaded in a running daemon.

```bash
spaceo daemon restart --operator   # drain: refuse new sessions, keep serving existing ones,
                                   # exit when the last one is destroyed, then start this build
spaceo doctor                      # daemon matches CLI: yes
```

While the daemon drains, agents that call `session.create` receive `daemon_draining`; the MCP
server retries the create for up to twenty seconds on their behalf, so an agent mid-task keeps
its session and a new agent simply waits. `--now` stops immediately instead of draining. If the
daemon is supervised by launchd (`spaceo daemon status`), launchd brings the new build back;
otherwise `restart` starts it from your shell and tells you which app the grants will attribute
to. The old three-step `daemon stop` / start dance still works.

**Daemons older than drain (1.0.x).** They answer `unknown command 'daemon.drain'`. `restart`
detects that and says so, then waits — up to `--timeout` seconds (default 900), printing the
live session count as it changes — until the old daemon has no live sessions, stops it, and
starts this build. It cannot refuse new sessions while it waits, so a busy host may never reach
zero; pass `--now` to stop it and its sessions immediately. Nothing is stopped when the wait
times out.

`doctor --fix` offers the same restart when the daemon does not match; it waits at most a
minute and never passes `--now`.

## Check each piece

**MCP clients.** MCP tools come from the `spaceo mcp` process the client launches, not from the
daemon, so a client whose config names an old copy keeps the old tools after the daemon is
upgraded. `spaceo doctor` reads each client's config (Claude Code user and project entries in
`~/.claude.json`, Codex, Cursor, Claude Desktop) without changing it, runs `<path> version`, and
marks stale entries. By hand:

```bash
which spaceo
claude mcp list                         # Claude Code
grep -A2 spaceo ~/.codex/config.toml    # Codex
```

Restart the client after an upgrade so it relaunches the new binary.

**Viewer.** `doctor` shows the installed Viewer's version (it looks in `/Applications` and
`~/Applications`). By hand:

```bash
defaults read "$HOME/Applications/SpaceO Viewer.app/Contents/Info.plist" CFBundleShortVersionString
```

Rebuild it with `make viewer` after a source update. An ad-hoc-signed Viewer may lose its
permission grants on rebuild; a Developer ID or Apple Development certificate keeps them.

**Toolchain (source builds).** SpaceO is built and tested on one exact toolchain:

```bash
xcodebuild -version     # Xcode 26.0.1
swift --version         # Swift 6.2
```

Other versions may build but are not qualified.

**Permissions.** macOS ties grants to the app that runs `spaceo`. After changing terminals, IDEs,
or MCP clients, run `spaceo doctor` from the new host and confirm both permissions are `ok`.

## Upgrade

**Release install:** follow the [Upgrade](INSTALL.md#upgrade) and
[Roll back](INSTALL.md#roll-back) procedures. Keep the previous DMG until the new one passes
`spaceo doctor` and your normal workflow.

**Source install:**

```bash
git pull
make install                        # rebuilds and replaces ~/.local/bin/spaceo
spaceo daemon restart --operator    # make install tells you when the old daemon is still running
make viewer                         # if you use the Viewer
spaceo doctor
```

Then restart your MCP clients. `make install` never restarts the daemon itself; it prints
`installed X over Y; the running daemon is still Y → spaceo daemon restart --operator` when one
is still serving the previous build.

## Checklist

- [ ] `spaceo version` shows the version you expect
- [ ] `spaceo doctor` says `daemon matches CLI: yes`
- [ ] Both permissions are `ok`, and `daemon can drive: yes`
- [ ] `spaceo doctor` lists no `STALE` MCP client entries
- [ ] Clients restarted
- [ ] Viewer version matches, and it still has its grants
