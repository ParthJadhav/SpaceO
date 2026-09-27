# SpaceO 1.0.0

SpaceO 1.0.0 is the first public release. It gives AI agents their own headless macOS displays,
so they can work in real applications while you keep using your Mac. Agent apps render off
screen, input goes to their windows, and your pointer and frontmost app stay yours.

This release covers native macOS apps and Chromium browsers on Apple Silicon.

## Highlights

- **A screen for every agent.** Sessions own apps, windows, and virtual displays, either
  dedicated or tiled on a shared display. Controller leases stop two agents from driving the
  same session, and their MCP servers renew them automatically.
- **34 MCP tools and a matching CLI.** Tools launch, adopt, and place apps. They read the
  Accessibility tree, find elements, read text, and take screenshots. They wait for conditions,
  click, type, press keys, scroll, drag, use menus, and select text. `spaceo_run_steps` batches
  actions, and every tool has a CLI equivalent (`spaceo help`).
- **Honest receipts.** Each action reports **confirmed**, **unconfirmed**, or **refused**, and
  after a native action it returns the changed elements with fresh indices. Isolation is checked
  and reported as intact, partial, or unknown, never assumed.
- **Accessibility first.** Indexed Accessibility elements are preferred over coordinates, with
  coordinate input for right-clicks, drags, and surfaces that have no element.
- **SpaceO Viewer.** A native app that shows every session live. Take Control to use an agent's
  app yourself, pause or resume an agent, and see which sessions need you.
- **Safe on failure.** Display-service failures are contained with bounded lifecycle waits,
  creation limits, and a persistent failure latch. Actions pause on known isolation breaches.
  Sessions can be recovered after a daemon restart, and `spaceo doctor` explains what is wrong
  with a host before you create a session.
- **Guided setup.** `spaceo setup` requests permissions, starts the daemon, runs a self-test,
  and prints MCP configuration for your agent clients.

## Supported apps

Native macOS apps and Chromium browsers (Chrome, Chromium, Edge, Brave, Vivaldi, Opera, Arc)
are supported. Managed Electron launches, including Cursor, VS Code, and Slack, are refused
before startup because their renderers can take desktop focus. Those editors can still connect
to SpaceO as MCP clients to drive supported apps.

## Install

Download `SpaceO-1.0.0-macOS-arm64.dmg`, `.sha256`, and `.sha256.sig` from this release.
Authenticate the checksum and the DMG as described in
[INSTALL.md](INSTALL.md) before running anything, then follow the
[setup guide](SETUP.md). You can also build from source with `make install`.

The DMG is Developer ID-signed (Team ID `75LRT8TRQY`), notarized, and stapled by the release
workflow. It ships with a signed checksum and a signed candidate record that binds the artifacts
to the exact commit, tag, and workflow run.

## Requirements and limits

- Apple Silicon (`arm64`) with macOS 14 or later, subject to runtime capability checks. SpaceO
  relies on private macOS display and input behavior and fails closed when a capability is
  missing. Intel is not supported.
- Accessibility and Screen Recording permissions.
- SpaceO isolates attention, not security. Agent apps run as your user with your files,
  network, credentials, and signed-in sessions. Use a separate macOS account when that matters.
- Canvas, game, 3D, and video surfaces may ignore background synthetic input; SpaceO reports
  such delivery as unconfirmed rather than claiming success.

## Qualification

The release source passes the deterministic Swift suite, the supervisor and Node tests, the MCP
smoke test, and the release-security and live-gate fixtures. The full live suite passed 16/16
with no skips, and the end-to-end MCP matrix passed 36/36, on Apple Silicon with macOS 27.2 and
mirrored 4K displays. See [the live qualification record](validation/2026-09-26-release-1.1.1-live.md);
display, input, and session code is unchanged since that run.

## Earlier previews

The `v1.1.0`–`v1.1.2` preview tags were withdrawn, and their prerelease was removed. If you
installed a preview DMG, install 1.0.0 over it and run `spaceo daemon restart --operator`.

See the [changelog](../CHANGELOG.md) for the full history.
