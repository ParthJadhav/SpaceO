# README screenshot

`viewer.png` is an unedited capture of SpaceO Viewer's `session` preview from the
2026-09-23 Viewer redesign. It uses `ViewerPreview.swift` fixtures: invented sessions,
sample screen content, and no real accounts, documents, leases, or Accessibility payloads.

The original local fixture capture was visually inspected before inclusion. A fresh capture
on 2026-09-24 was blocked by the daemon's Accessibility permissions; it was not used.
To reproduce on an eligible host, run `scripts/viewer-snapshots.sh session`.

## Recorded Viewer GIF

`viewer-demo.gif` is a 14.2-second, 1120×700 recording of the real Viewer on 2026-09-24.
It switches from the flight session to the invoice needing human assistance, then the
release-notes session, and back. Session selection used public Accessibility actions.
The live UI was captured using ScreenCaptureKit; the sample app pixels come from the
explicit synthetic preview fixture, not real web pages, documents, or accounts.

The capture used a separate current-build daemon and a dedicated preview session.
All three state changes were verified against the Viewer Accessibility tree.
The preview session and its daemon were removed afterward. The GIF is silent, loops,
and uses a 128-color palette at 10 fps; raw footage and capture scripts remain private
in ignored local artifact storage.
