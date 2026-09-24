# Coordinates: turning a screenshot pixel into a click

Every SpaceO point argument (`x`, `y`, `to_x`, `to_y`, and scroll/move points) is a
**window-local point**: measured from the target window's top-left corner, in points, not
pixels and not global screen coordinates. A screenshot pixel is not automatically a point. The
`image` geometry returned with every `spaceo_screenshot` tells you how to convert, and its
`advice` field states the exact formula for that capture. Trust that line over memory.

## Window capture at scale 1 (the default)

`spaceo_screenshot` with only `window` (or nothing) and `scale: 1`:

> Image pixels are window-local points: click these coordinates directly.

`origin: window`, `scale: 1`. The pixel you read is the point you click.

## Window capture at a higher scale

`scale: 2` (or 3, 4) for reading small text:

> Image is 2x window-local. Divide pixel coordinates by 2 to get click coordinates:
> x = pixel_x / 2, y = pixel_y / 2.

Prefer to keep `scale: 1` for anything you intend to click.

## Tile or region capture

`full: true` (the whole tile) or `x`/`y`/`width`/`height` (a tile-relative region) is measured
from the capture's own **global** origin, not from any window. The advice reads, with the
capture's real origin substituted in (here 1512, 0):

> Image pixels are points measured from this capture's global origin (1512, 0), not from any
> window. click takes window-local points, so: x = pixel_x + 1512 - windowX,
> y = pixel_y + 0 - windowY, where windowX/windowY are the target window's x/y from list_windows.

At scale 2 the first term becomes `pixel_x / 2`. The general formula, with image origin
(`originX`, `originY`), `scale`, and the target window's `x`/`y` from `spaceo_list_windows`:

```
x = pixel_x / scale + originX - windowX
y = pixel_y / scale + originY - windowY
```

All three terms are load-bearing. Omitting `+ originX` puts a tile screenshot's coordinates a
whole tile away from the window, which `spaceo_click` refuses as out of bounds. For a window
capture the two origins are the same window, so those terms cancel and the formula degrades to
`pixel / scale`.

For a zoomed region, `originX`/`originY` are the region's origin, not the tile's, so neither the
tile origin nor the window origin alone converts it. Use the values from that capture's own
geometry.

## The geometry fields

| Field | Meaning |
|---|---|
| `origin` | `window` — coordinates are window-local. `tile` — measured from `originX`/`originY` |
| `scale` | Pixels per point. Divide a pixel coordinate by this |
| `pixelWidth`, `pixelHeight` | Image size in pixels |
| `pointWidth`, `pointHeight` | Captured area in points |
| `originX`, `originY` | Global-screen origin of the captured area |
| `windowID` | The window a `window` capture belongs to; absent for a tile capture |
| `advice` | The one-line formula for this capture |

## Capture limits

Capture and image processing share a 15-second budget after the command is admitted; a timed-out
capture worker must finish before another screenshot can start. In-memory PNGs (what MCP
returns) are limited to 5 MiB, and native frames to 64 Mi pixels after scaling: lower `scale` or
capture a smaller region if you hit either. `capturedAt` records when the capture backend
returned the image, before processing; pixel freshness and visibility remain unknown and
presentation is unverified.

## Web pages

With `web: true` on click, scroll, move, or drag, `x`/`y` are CSS viewport coordinates — the
numbers `spaceo_read_screen` prints beside each `wN` element — and none of the above applies.
Never feed screenshot-derived numbers to a `web: true` call. See `spaceo://docs/drive-web`.

## Geometry tokens

Window geometry receipts carry a `geometry` token. Pass it with a coordinate click or drag so
the daemon can refuse with `stale_geometry` if the window moved or the backing scale changed
between your screenshot and your click. On `stale_geometry`, call `spaceo_list_windows`, then
either retry with the new token or, better, use an element index.

## When not to use coordinates at all

An element index from `spaceo_read_screen` cannot miss and survives the window moving. Use
coordinates only for a right-click, double-click, modifier-held click, a drag between points, or a
point with no accessibility element. `spaceo_scroll`, `spaceo_move`, and `spaceo_drag` accept
`element` / `from_element` / `to_element` instead of a point and report the `resolved_point`, so
you can often avoid the arithmetic entirely. `spaceo_screenshot` with `annotate: true` draws the
indices onto the image so vision and index workflows agree.


Screenshot capture and image processing share a 15-second budget after command admission.
A timeout or cancellation discards late worker results; another screenshot is refused until
that worker actually finishes. Session teardown keeps the tile reserved and reports incomplete
cleanup until a later retry can finish. In-memory PNGs are limited to 5 MiB and CLI file PNGs
to 64 MiB. Native framebuffers are limited to 64 Mi pixels after scaling; reduce scale or
region size if exceeded. Geometry is rechecked before publishing.
Local file publication still uses an atomic filesystem write and is not preemptible by this
processing deadline. No requested output file is written by a timed-out worker.


The capture receipt's `capturedAt` records when the backend returned the image, before annotation,
encoding, or saving. Processing delays do not advance that timestamp. It is a wall-clock
observation time, not a renderer or scanout timestamp: pixel freshness and visibility remain
`unknown`, and presentation remains `unverified`. Do not treat the receipt time as proof that
an action has appeared on screen; use an appropriate observed postcondition.
