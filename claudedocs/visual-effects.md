# Experimental Visual Effects (Halftone & Frosted Neon)

Two real-time GPU shaders that re-render a live UIKit view through Metal, plus a
media-preview playground for each. Both live under **Settings → Experimental** and
are intentionally **forked, not shared** — each effect is a self-contained copy so
they can diverge freely.

## Where things live

| Area | Halftone | Frosted Neon |
|---|---|---|
| Shader | `ClipLibraries/.../ClipContentRendering/Halftone/HalftoneShaders.metal` | `.../FrostedGlass/FrostedGlassShaders.metal` |
| Effect view | `Halftone/HalftoneEffectView.swift` | `FrostedGlass/FrostedGlassEffectView.swift` |
| Persisted settings | `Clip/Settings/HalftoneSettings.swift` | `Clip/Settings/FrostedGlassSettings.swift` |
| Settings + preview screen | `Clip/Settings/HalftoneSettingsScreen.swift` | `Clip/Settings/FrostedGlassSettingsScreen.swift` |
| Entry rows | `Clip/Settings/ExperimentalSettingsScreen.swift` | same |

The `.metal` files compile into `Bundle.module`'s `default.metallib` (loaded first
in `buildPipeline`).

## Architecture

- `UIView.applyHalftone(_:)` / `applyFrostedGlass(_:)` insert the effect view as a
  **sibling above** the source view (never a child — that would feed the effect's
  own Metal layer back into the capture and loop).
- The effect view's layer is a `CAMetalLayer`. Each frame:
  1. `CARenderer` renders the **source layer tree** into an IOSurface-backed
     `MTLTexture` (zero-copy, GPU, captures in-flight Core Animation state).
  2. A full-screen-triangle fragment shader samples that texture and produces the
     effect into the drawable.
- **GPU only** — no CPU pixel work on the hot path (there is a CPU `cpuSnapshot`
  fallback only when Metal capture is unavailable).
- Capture is done at **point resolution** (1x), drawing at up to 2x; the coarse
  grid/blur hides the difference and cuts fragment cost.
- `hitTest` returns `nil` in passive mode so touches fall through; in
  `ripplesOnTap` mode it takes touches so its own tap/drag recognizers fire.

### Performance (idle-parking)

The display link **parks itself** when nothing is changing — a settled image costs
zero GPU. It wakes via:
- `setNeedsCapture()` — source content changed (new media, video/GIF frame, resize).
- config change / ripple / drag — re-runs the shader on the cached texture (no
  re-capture).

`renderFrame` guards on `rippleRunning || dragActive || needsRender || needsCapture`
and re-parks once the latest state is on screen. Live video/GIF drive a per-frame
`CADisplayLink` (`liveTick`) that calls `setNeedsCapture()`; static images capture
exactly once.

## Ripple transition

Tap the preview to fire an expanding wavefront from the touch point that reveals or
hides the effect, pushing the content radially as it passes. Dispersion adds damped
trailing ripples. Duration "Auto" fits the wave to the farthest corner. The
wavefront softness is the **Reveal Edge**. (The earlier per-dot "flip" animation was
removed in favour of this clean reveal/push.)

## Halftone-specific controls

- **Dot Spacing** — grid-pitch multiplier (`pitch = cellSize * dotSpacing`).
- **Dot Size** — fraction of a cell the dot fills; **decoupled from spacing**, so it
  can exceed 1× and overlap neighbours.
- **Transparent Background** — the un-rippled state is fully transparent, so a tap
  ripples the dots in/out over a clear background.
- **Drag (finger-follow)** — dragging pulls nearby dots toward the finger (springy,
  GPU-side), snapping back past *Snap-Back Distance*. *Strength 0* disables it.
- Plus grid angle, jitter, shape/corner, edge softness, brightness, opacity,
  greyscale, gap colour/blur/source-mix.

## Frosted-Neon-specific controls

Frost blur + scatter, neon glow (threshold/intensity/radius, additive option),
neon tint colour, saturation/brightness.

## Media preview

Each screen pins a live preview footer: pick a photo/video/GIF; settings update it
live. Images are normalized to `.up` (EXIF baked in) and videos honour their track
`preferredTransform`, because the GPU capture ignores `UIImage.imageOrientation`.
A **fullscreen toggle** expands the preview to fill the screen (aspect-fit) and back.

## Testing notes

- The effect itself can't be exercised in the simulator via UI automation: the
  media picker is `PHPickerViewController` (out-of-process, untappable via
  injection). Pick media by hand on device/TestFlight.
- Top nav-bar bar-button items are flaky to tap via Blitz injection; content-area
  taps work normally.
- Archive/TestFlight with stable Xcode 26.2 (Xcode 27 beta swiftc crashes
  optimizing SwiftSoup). Build numbers run ahead of the pbxproj — check
  `asc builds list --app 6778648023` first.
