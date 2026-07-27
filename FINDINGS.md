# Isolating AI agents from the user on macOS

Investigation notes from a historical prototype and its failed release-hardening pass. Everything
marked **[verified]** was observed on this machine, but verification of a narrow behavior is not
a safety or release claim: macOS 27.0 (build 26A5368g), Apple Silicon, **SIP enabled**.

---

## 1. The question, restated precisely

An agent driving a Mac steals three global, singleton resources:

| Resource | Owner | Why it hurts |
|---|---|---|
| The mouse cursor | one per login session | user loses pointer mid-sentence |
| Keyboard focus / frontmost app | one per login session | keystrokes land in the wrong app; menu bar changes |
| Screen real estate | the displays | agent windows cover the user's work |

Plus two the user asked about implicitly: Mission Control **Spaces**, and app **activation**
(which yanks the user to whatever Space the activated app lives on).

The naive framing is "give the agent its own Space." That turns out to be the wrong primitive.
The right primitive is one level up: **give the agent its own display.**

---

## 2. Why Spaces are the wrong answer

Three independent reasons, in increasing order of severity.

### 2.1 You cannot create or switch a managed Space without disabling SIP

The entire Mission Control / Spaces state machine lives inside **Dock.app**, which holds the
privileged WindowServer connection for space management. `SkyLight.framework` exposes the
primitives — `SLSSpaceCreate`, `SLSSpaceDestroy`, `SLSManagedDisplaySetCurrentSpace`,
`SLSShowSpaces`/`SLSHideSpaces` — but the *managed* space list is Dock-owned state. This is
exactly why `yabai` requires SIP to be partially disabled: it injects a scripting addition into
Dock.app. ([yabai wiki](https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection))

Notably, **moving an existing window to an existing space does *not* need SIP off** — only
creating/destroying/focusing does. So a "use spaces the user pre-created" design is possible.
It still fails for reason 2.3.

### 2.2 Activation drags the user across Spaces

macOS's default "when switching to an application, switch to a Space with open windows for that
application" means any agent action that *activates* an app teleports the user. Avoidable, but
only by never activating — which is the technique in §4.3 anyway.

### 2.3 The killer: a window on an inactive Space is officially "not visible"

From Apple's own energy-efficiency guidance: *your app is considered hidden when windows of other
apps occlude it **or when your app is in a Mission Control space where the user isn't working***.
`NSWindowOcclusionStateVisible` clears, and well-behaved apps are explicitly told to *halt
drawing*.
([Apple docs](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/WorkWhenVisible.html))

For an agent this is fatal: the app it is trying to watch stops rendering, animations freeze, and
— as `cua` found in production — **Electron accessibility trees pause during occlusion**, forcing
them onto the private `_AXObserverAddNotificationAndCheckRemote` to keep AX alive.
([cua blog](https://cua.ai/blog/inside-macos-window-internals))

A window on a **second display's active Space is genuinely visible**. No occlusion, no App Nap,
no AX pausing, no private hacks. That is the whole insight.

---

## 3. What the private API surface actually offers (macOS 27)

**[verified]** All of the following resolve via `dlsym` against
`/System/Library/PrivateFrameworks/SkyLight.framework` from an **unsigned** binary with **SIP on**
(`probes/probe2.m`). The probe now performs symbol inventory only; it never calls the unsafe focus
getters. SkyLight exports 2,895 symbols; CoreGraphics re-exports the public event API straight out
of it — `CGEventPostToPid` *is* `SLEventPostToPid`.

### Three separate notions of "focus"
macOS tracks these independently, which is what makes background driving possible at all:

```
SLPSGetFrontProcess        // the app owning the menu bar   <- the user's
SLPSGetKeyFocusProcess     // who receives key events
SLPSGetTypingFocusProcess  // who receives text input
```

**[safety correction, 2026-07-26]** A symbol name resolving is not an ABI check. Calling the
two getters through the former one-pointer declarations corrupted memory on macOS 27; crash
reports place the failure in `GetProcessPID` after the private call wrote incompatible output.
No replacement signature is assumed, and neither symbol is resolved or called. Focus-driven
sessions instead restore and verify the user's frontmost route through public AppKit state.

Plus the levers to move them apart:

```
SLPSPostEventRecordTo          // flip an app's AppKit-active state, no raise, no space switch
SLPSSetFrontProcessWithOptions // the one that DOES raise + follow spaces — never call this
SLPSStealKeyFocus / ReleaseKeyFocus
SLSSetAvoidsActivation / SLSSetPreventsActivation / SLSSetDeferActivation
SLSSpaceSetFrontPSN            // per-space front process
SLSSetMouseFocusWindow
```

### Per-process event delivery
```
SLEventPostToPid  /  SLEventPostToPSN  /  SLPSPostEventRecordTo
SLEventTapCreateForPid / ForPSN
```

### Space graph (read side is free, write side is Dock-gated)
```
SLSCopyManagedDisplaySpaces, SLSGetActiveSpace, SLSCopySpacesForWindows,
SLSSpaceCreate/Destroy, SLSMoveWindowsToManagedSpace, SLSAddWindowsToSpaces,
SLSSpaceSetAbsoluteLevel, SLSSpaceSetAlpha, SLSSpaceSetTransform
```

### Capture, including whole-space capture
```
SLSHWCaptureSpace                              // rasterise an entire Space to an IOSurface
SLSHWCaptureProcessWindowsInSpaceIncludeDesktop
SLSHWCaptureWindowList / InRect / ToIOSurfaceProxied
SLSTransactionAddWindowToCaptureGroup          // keep a window live while occluded
```

### Cursor containment
```
SLSSetCursorRestrictionMode, SLSSetCursorRegionLock, SLSWarpCursorPosition
```

### Virtual displays (CoreGraphics, private)
**[verified]** `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode`,
`CGVirtualDisplaySettings` all present with intact signatures (`probes/probe3.m`):
```objc
-[CGVirtualDisplayMode initWithWidth:height:refreshRate:]
-[CGVirtualDisplayMode initWithWidth:height:refreshRate:transferFunction:]
-[CGVirtualDisplay initWithDescriptor:]  /  -applySettings:  /  @property displayID
-[CGVirtualDisplaySettings setHiDPI:] setModes: setRotation: setIsReference: setRefreshDeadline:
```
Same API BetterDisplay / DeskPad / Mirage use.

---

## 4. The architecture: one headless display per agent

### 4.1 Stage — a virtual display the user cannot see
**[verified in an isolated probe]** `probes/vdisplay.m` creates a 1920×1080 HiDPI display in
~200 ms and the display normally vanishes on exit. **[counterexample, 2026-07-26]** rapid
create/retire churn on the macOS 27 preview host left three vendor-tagged SpaceO displays attached
after every owning process exited. Process lifetime is therefore the normal behavior, not a
crash-safety guarantee; production must verify teardown and refuse to add displays when an
ownerless one exists.

**[policy superseded, 2026-07-27]** The owner directed removal of the ownerless-display creation
block. Current production code reports ownerless IDs but does not refuse another attachment.

**[verified]** The virtual display gets **its own managed Space**, reported as a second entry in
`SLSCopyManagedDisplaySpaces` with `spaces=1`. That Space is always the current Space *of that
display*, so windows on it are always composited.

**[verified — and then rejected]** **Diagonal parking does not survive contact with teardown.**
Asking for origin `(12000, 9000)` does make macOS clamp to `(1920, 1080)`, the corner-touch
position, and corner contact genuinely is not traversable by the cursor. But
`probes/probe7.m` shows the price:

| mode | result |
|---|---|
| create → release | display gone in 0.5 s |
| create → `CGConfigureDisplayOrigin` → release | **still attached after 10 s** |
| create → park → `CGRestorePermanentDisplayConfiguration()` → release | **still attached after 10 s** |

Worse, once a display has been through `CGConfigureDisplayOrigin`, **every virtual display
created afterwards in that process comes up with zero bounds** and is unusable. One park call
poisons the process.

So SpaceO does not park. The production package contains no `CGConfigureDisplayOrigin` mutation,
diagonal-parking API, cursor-fence implementation, or pointer-warp path.

**[historical probe]** Four extra virtual displays once created simultaneously, each with its own
ID and Space, and tore down cleanly (`probes/probe6.m`). The later ownerless-display incident
invalidated the inference that this was a viable or safe scaling model.

### 4.2 Placement — get windows there without a flash
```swift
let cfg = NSWorkspace.OpenConfiguration()
cfg.activates = false          // do not steal the menu bar
cfg.addsToRecentItems = false
```
Then an `AXObserver` on `kAXWindowCreatedNotification` sets `kAXPosition` into the agent display's
rect on the first frame. **[verified]** `AXUIElementSetAttributeValue(win, kAXPositionAttribute,…)`
relocates another app's window onto the virtual display with no cursor movement and no activation.

To eliminate even the one-frame flash, pre-seed the app's window autosave frame in its
`NSWindow Frame <name>` default so it *opens* on the agent display.

### 4.3 Input — drive it without taking anything
Order matters:

1. **Focus without raise** — yabai's technique, faithfully reimplemented in `probes/probe4.m`:
   ```c
   uint8_t b[0xf8] = {0};
   b[0x04] = 0xf8; b[0x08] = 0x0d;      // activation record
   memcpy(b + 0x3c, &wid, 4);
   memset(b + 0x20, 0xff, 0x10);
   b[0x8a] = 0x01;                       // "you are active for input routing"
   SLPSPostEventRecordTo(&psn, b);
   // then make-key: b[0x3a]=0x10, post with b[0x08]=0x01 then 0x02
   ```
   Never call `SLPSSetFrontProcessWithOptions` — that is the one that raises and follows Spaces.
2. **Keys** — `CGEventPostToPid` (= `SLEventPostToPid`) with `CGEventKeyboardSetUnicodeString`.
3. **Mouse** — same per-PID channel, window-local coordinates. For Chromium, `cua` reports the
   renderer validates event provenance and you need a primer click at `(-1,-1)` first.
4. **Prefer AX over pixels** — `AXUIElementPerformAction(kAXPressAction)` and setting `kAXValue`
   are coordinate-free, need no focus at all, and cannot miss.

### 4.4 Vision
ScreenCaptureKit `SCContentFilter(display:excludingWindows:)` on the agent's virtual display gives
a clean, complete framebuffer. Per-window, `SCContentFilter(desktopIndependentWindow:)` is
documented as display- and Space-independent and includes full window content even when occluded.
`SLSHWCaptureSpace` is the private whole-Space equivalent if you want an IOSurface directly.

### 4.5 Historical end-to-end result (not a safety proof)

The mutating research probes used for this result are unrestricted as of 2026-07-27. Compiled
probe binaries are not retained in the source tree.

`probes/probe4.m` completed once while the user's browser stayed frontmost:

```
virtual display 6 bounds = 1920,0 1920x1080
frontmost pid BEFORE      = 57826 (Zen)

[1] managed spaces per display
    E58E7BBF-…  spaces=2      <- user's physical display
    5BA67452-…  spaces=1      <- agent's virtual display, own Space

[2] moved window 7544 -> (2040,120) setPos=0 setSize=0
    window now at 2040,120 900x640  onVirtualDisplay=YES

[3] focus-without-raise + per-PID keystrokes
    AX focused element value = SpaceO agent typed this while you kept working.

[5] frontmost pid AFTER     = 57826 (Zen)   UNCHANGED=YES
```

`screencapture -l 7544` returned a fully rendered 900×640 window with live text —
**no occlusion, no blank backing store**. The cursor never moved. The menu bar never changed.

### 4.6 Containment and diagnostics
The parts that are engineering, not research:
- **Pasteboard** — the general pasteboard is shared and agents *will* clobber it. Save/restore
  around agent copy/paste, or route agent text through AX `kAXValue` and never use the clipboard.
- **Notifications / Dock / Cmd-Tab** — agent apps still appear in Cmd-Tab and can post banners
  onto the user's screen. Mitigate with a Focus filter; cannot be fully solved on-host.
- **Watchdog** — re-park escaped windows, verify virtual-display removal, and inventory ownerless
  vendor-tagged displays without blocking subsequent creation.

---

## 4.7 Chromium: measured, not assumed

The earlier draft repeated cua's claim that Chromium right-clicks get coerced to left-clicks and
that a primer click at `(-1,-1)` fixes mouse delivery. Tested against Google Chrome on macOS 27,
the reality is simpler and worse:

| attempt | result |
|---|---|
| keyboard via `CGEventPostToPid` | **works** — address bar receives text |
| `AXPress` on a browser toolbar control | **works** |
| `AXPress` on a DOM button | no DOM click |
| synthetic mouse at the right coordinates | no DOM click |
| ...with a primer click at `(-1,-1)` first | no DOM click |
| ...stamped with `kCGMouseEventWindowUnderMousePointer` | no DOM click |

Nothing synthetic reaches web content. The fix is not a trick, it is to use the channel browsers
provide: launch with `--remote-debugging-port` and dispatch through
`Input.dispatchMouseEvent`. With that, left clicks, right clicks and text all land — verified by
a page that counts them (`Tests/.../testChromiumWebContentIsDrivenThroughDevTools`).

The corollary matters more than the fix: a browser SpaceO did not launch has no port, and a
click there **silently does nothing**. An agent that believes it clicked is worse off than one
told it cannot, so that case is a hard error.

## 5. Where this approach runs out, and what to do then

| Failure mode | Why | Escape hatch |
|---|---|---|
| Canvas apps (Blender, Unity, games) | reject per-PID event routing entirely; need a real cursor | second Aqua session, or VM |
| Chromium web content | renderer drops all synthetic input | DevTools, for browsers we launch (§4.7) |
| Self-activating Electron shells | call `NSApp.activate` on startup | hand focus back, and report it |
| DRM / capture-protected windows | `kCGWindowSharingState = 0` | VM |
| Agent must be *fully* untrusted | shares filesystem, keychain, network with the user | VM |

### Tier 2 — a second Aqua login session (full isolation, no VM)
macOS gives a second logged-in user **its own WindowServer namespace**: own cursor, own frontmost
app, own Spaces, own menu bar, own pasteboard. Apple's documented behaviour is that when a console
user is logged in and a second user connects via Screen Sharing, *the remote user gets a generic
virtual screen* rather than the real displays — precisely the isolation we want, fully supported.
Combine with a `CGVirtualDisplay` inside that session (this is what Mirage sells for headless
Macs) so the framebuffer persists after the Screen Sharing client disconnects. Drive it over SSH +
`launchctl asuser <uid2>`.

Cost: a second user account, separate app logins/keychain, ~2–4 GB RAM.

### Tier 3 — VM (what cua does)
`lume` runs macOS/Linux guests on `Virtualization.framework` at near-native speed on Apple
Silicon. Total isolation, snapshot/restore, reproducible.

**Important current caveat:** macOS 26/27 guests under Virtualization.framework
**are not compositing application windows** — windows register in the guest WindowServer with a
~2 KB backing store instead of ~1 MB and `kCGWindowSharingState = 0`, so both screen capture and
VNC come back blank. [trycua/cua#912](https://github.com/trycua/cua/issues/912) is **open and
unresolved**. Linux guests are unaffected. If you need a macOS guest today, pin the guest to
Sequoia.

---

## 6. Honest gaps

Historical probes demonstrated display creation/scaling, own-Space allocation, diagonal parking,
cross-app window relocation, focus-without-raise, per-PID **keyboard** delivery, and capture.
Repeated end-to-end testing later invalidated the safety claim: the physical displays became
inactive, ownerless virtual displays remained, and the assumed focus-getter ABI corrupted memory.
The current build disables both private capabilities and makes no zero-disturbance release claim.

**Not** verified here, and worth testing before committing:
- per-PID **mouse click** delivery (keyboard was tested; cua documents mouse works with the
  Chromium primer-click caveat)
- ScreenCaptureKit streaming specifically (capture was validated via `screencapture`/window list)
- AX tree liveness on a virtual display over hours
- HiDPI/Retina coordinate mapping for click targeting on the virtual display

Private API risk is not bounded by `dlsym`: the crash involved symbols that were present.
A releasable capability gate needs version-specific ABI validation, behavioral qualification,
and a safe recovery boundary. The current build fails closed before display or focus mutation.

---

## Sources

- [cua — Inside macOS window internals: how SkyLight enables multi-cursor background agents](https://cua.ai/blog/inside-macos-window-internals)
- [cua / lume](https://github.com/trycua/cua) · [issue #912 — Tahoe VM windows not rendering](https://github.com/trycua/cua/issues/912)
- [yabai `window_manager.c`](https://github.com/koekeishiya/yabai/blob/master/src/window_manager.c) · [Disabling SIP wiki](https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection)
- [Apple — Work When Visible (occlusion & Spaces)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/WorkWhenVisible.html)
- [Apple — Capturing screen content in macOS (ScreenCaptureKit)](https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos)
- [Apple — `CGEventPostToPid`](https://developer.apple.com/documentation/coregraphics/1456527-cgeventposttopid)
- [w0lfschild/macOS_headers — CGVirtualDisplay.h](https://github.com/w0lfschild/macOS_headers/blob/master/macOS/Frameworks/CoreGraphics/1336/CGVirtualDisplay.h)
- [Mirage — virtual display for headless Macs](https://mirageai.dev/)
- [Apple — Screen Sharing virtual displays](https://support.apple.com/guide/mac-help/mh14066/mac)
