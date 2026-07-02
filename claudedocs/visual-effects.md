# Experimental Visual Effects (Dot Matrix & Frosted Neon)

Two real-time GPU shaders that re-render a live UIKit view through Metal, plus a
media-preview playground for each. Both live under **Settings → Experimental** and
are intentionally **forked, not shared** — each effect is a self-contained copy so
they can diverge freely.

## Where things live

| Area | Dot Matrix | Frosted Neon |
|---|---|---|
| Shader | `LunaLibraries/.../LunaContentRendering/DotMatrix/DotMatrixShaders.metal` | `.../FrostedGlass/FrostedGlassShaders.metal` |
| Effect view | `DotMatrix/DotMatrixEffectView.swift` | `FrostedGlass/FrostedGlassEffectView.swift` |
| Persisted settings | `Luna/Settings/DotMatrixSettings.swift` | `Luna/Settings/FrostedGlassSettings.swift` |
| Settings + preview screen | `Luna/Settings/DotMatrixSettingsScreen.swift` | `Luna/Settings/FrostedGlassSettingsScreen.swift` |
| Entry rows | `Luna/Settings/ExperimentalSettingsScreen.swift` | same |

The `.metal` files compile into `Bundle.module`'s `default.metallib` (loaded first
in `buildPipeline`).

## Architecture

- `UIView.applyDotMatrix(_:)` / `applyFrostedGlass(_:)` insert the effect view as a
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

## Dot Matrix-specific controls

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

## Dot Matrix pixel-wipe TRANSITIONS (the facade) — region-confined wipes

Separate from the effects playground above: the **`LunaTransitions`** library wraps the
`LunaContentRendering` Metal dissolve (`RabbitHoleTransitionView`) into UIKit transition
helpers, all gated on `DotMatrixTransitionCenter.shared.isEnabled` — the
`AppearanceSettings.animatedTransitionsEnabled` preference AND `!UIAccessibility`
`.isReduceMotionEnabled` AND Metal availability; false ⇒ stock UIKit animation.

Both `AppearanceSettings` preferences are user-facing under **Settings → Appearance**
(`Luna/Settings/AppearanceSettingsScreen.swift`): a **Theme** segmented control
(System / Light / Dark) that writes `AppearanceSettings.interfaceStyle` and applies it
live to every connected scene's windows (`AppearanceSettings.apply(to:)`, also called at
each window-creation site — `SceneDelegate`, the `DotMatrixModal` cover window, and the
`DotMatrixKeyboardReveal` cover window), and a **Motion** toggle bound to
`animatedTransitionsEnabled`.

Surfaces: `DotMatrixCrossfade` (in-place view change), `DotMatrixBatch` (table row
updates), `DotMatrixModal` (modal present/dismiss — see below),
`DotMatrixTransitionSession` (nav push/pop). The RabbitHole reader's
dive/pop/overscroll uses the `RabbitHoleTransitioning` protocol (`LunaReaderUI`),
with the app-side Metal impl `Luna/Social/DotMatrixRabbitHoleTransition.swift`.

### Modal present/dismiss (`DotMatrixModal`) — cover-window choreography

Every modal in all three apps (alerts, action sheets, bottom/form sheets, popovers,
full-screen covers) presents/dismisses through `DotMatrixModal.present(_:from:)` /
`DotMatrixModal.dismiss(_:)`. It does NOT use a `UIViewControllerTransitioningDelegate`
(the removed first attempt — the transition container is empty for sheet/alert
presentations, the dimming/stack-back chrome is private, and `UIAlertController` can't
take a custom delegate; that's where the old artifacts came from). Instead the
presentation really happens `animated:false` under an opaque **cover window** (level
normal+50, below status bar/keyboard) showing a pre-captured screen snapshot, and the
animation plays on top with real committed pixels:

- **Partial-screen present**: (1) *chrome fade* — everything outside the modal's
  resolved frame (dimming, sheet stack-back) crossfades between two full-window
  snapshots over `chromeFadeDuration` (0.12s), never pixelating; (2) *region wipe* —
  the two-wave dissolve confined to the modal's pixel-aligned frame (the modal-free
  background is captured by briefly hiding the presentation's chrome view under the
  cover). Dismiss mirrors it (wipe first, then un-dim fade). A final 0.08s cover fade
  over the live UI softens anything snapshots can't know (shadows, mid-wipe motion).
- **Full-screen present/dismiss**: one whole-screen wipe, like a nav push.
- **Directions** (`DotMatrixModalStyle.automatic`, resolved from REAL post-layout
  geometry so iPhone/iPad adaptations pick the right feel): full-screen and
  bottom-anchored-wide modals = *movement* (`.bottomToTop` present / `.topToBottom`
  dismiss); everything else (alerts, popovers, centred sheets) = *appear-in-place*
  (`.random` — dots of the final UI materialise at their final position, then a second
  random wave sharpens them).
- **Timing**: modals are deliberately FASTER than every other wipe (they block input):
  the wipe plays the global timeline at HALF wall duration (`wipeDuration`), chrome
  fade 0.08s (`modalChromeFadeDuration`), reveal fade 0.06s. Other surfaces keep the
  full configured timeline + the shared 0.12s `chromeFadeDuration`.
- **Fallbacks** (stock UIKit animation): toggle off / Metal missing, `animated:false`,
  `UIView.areAnimationsEnabled == false` (tests), no window scene (app extensions),
  remote out-of-process content that snapshots blank (`UIActivityViewController`,
  `SFSafariViewController`, PH/document/image pickers — these keep stock animations
  BY DESIGN), a modal stacked on top at dismiss time. Any mid-flight snapshot failure
  degrades to an instant cut with the cover fading out — the screen can never be left
  covered. `NavHeaderTableController.modalDismisser` (LunaDesignSystem sits below
  LunaTransitions) is injected in AppDelegate so header-screen modal dismissals wipe.

### Inline reader / lightbox opens (content wipes, chrome fades)

`DotMatrixCrossfade.run(... chromeFade: true)` adds a full-view snapshot of the
pre-change screen that fades out over `chromeFadeDuration` while the region wipes —
for changes where the area OUTSIDE the region also changes but must only fade:

- **Split-web inline reader** (`SplitWebOverlayViewController`): open/close wipes ONLY
  the area that becomes the card's content (open card frame below its 68pt header);
  the card header, peeks, dim, and chevron fade. Snapshots come from the WINDOW (the
  overlay's own view is transparent at the margins/RSVP backdrop). The interactive
  peek-drag keeps the live spring (including a drag-committed close — no style switch
  mid-gesture); ✕/chevron closes wipe. Inner page push/pop wipes via
  `DotMatrixAnimator` from the overlay's own nav delegate (the wipe overlay lives in
  the nav container INSIDE the card, so the floating header stays live and static).
- **Image lightbox** (`ImageLightboxViewController`): the image's final frame
  materialises appear-in-place; dimming/close button fade. Close mirrors it (the
  "after" restores the image copy onto its inline source frame). The drag-to-dismiss
  fling stays live.
- **Reading-list search overlay** (`ReadingListViewController`): the full-surface
  in-place overlay show/hide is a plain full-bounds `DotMatrixCrossfade` (it replaces
  the whole surface, header included).

### RabbitHole dive/pop: content wipes, chrome fades (`contentRegion`)

`RabbitHoleTransitioning.play/begin` take a `contentRegion` alongside `region`: only
the DESTINATION focused layer's content area (its card below the 64pt floating header
— `RabbitHoleReaderViewController.destinationContentRegion`) PIXELATES; the rest of
the changed region (layer headers, lips, moving card chrome) CROSSFADES on a pair of
before/after image views under the overlay (`DotMatrixRabbitHoleTransition.Stage`),
tracking the finger 1:1 in the interactive overscroll/edge pops. nil ⇒ the whole
region pixelates (old behaviour; the extension-side default overloads pass nil).

### Keyboard appearance (`DotMatrixKeyboardReveal` + the engine's dissolve-out mode)

The keyboard is out-of-process and CANNOT be snapshotted, so its wipe runs backwards:
`RabbitHoleTransitionView.dissolvesOut` pixelates the BEFORE texture into dots over
TRANSPARENT gaps and fades them away (premultiplied blending; `returnOverlay` resets
the mode), revealing whatever LIVE content sits beneath the layer. On
`keyboardWillShow` a touch-transparent patch window ABOVE the keyboard's window
(level 2e7) holds the pre-keyboard pixels — copied from the modal cover's image when
one is up (`DotMatrixKeyboardReveal.activeCover`), else the live window — the
keyboard rises invisibly beneath it, and on `keyboardDidShow` the patch dissolves out
in 0.15s (bottom-to-top wave). Frame CHANGES while visible, hardware-keyboard bars
and floating iPad keyboards are ignored; a hide mid-reveal tears down instantly.
Installed once in AppDelegate via `DotMatrixKeyboardReveal.install(windowProvider:)`
(a closure, so the library stays extension-safe).

**Intentional exclusions**: the settings preview stage expand/collapse (DotMatrix /
FrostedGlass / Stone screens) — it resizes a LIVE continuously-re-capturing Metal
effect view, which a frozen snapshot wipe would visibly fight; toasts, spinners,
gesture snap-backs and other micro-interactions per the rule below.

### Timing model (two waves, `DotMatrixTransitionStyle`)

The wipe is one `progress` 0→1 ramp over `totalDuration`; the shader normalises its
timeline by `span = sweep + lag + win`, so the per-cell wall times are `(sweep/span)·total`
(wave-1 front sweep), `(lag/span)·total` (wave-1 → wave-2 START gap) and `(win/span)·total`
(one cell's fade). `DotMatrixTransitionStyle` therefore expresses `sweep`/`lag`/`win` as
the actual wall-second budgets normalised to sum to 1 and sets `totalDuration` to their sum,
so each fraction lands on its exact wall duration. **Fixed values:** wave 1 = wave 2 = **0.1s**
each (`phase1Duration`/`phase2Duration`, averaged into the shared sweep), the gap between the
two wave STARTS = **0.2s** (`interWaveDelay` — larger than the wave durations, so the screen
briefly holds the fully-pixelated state between the fronts), per-cell fade from `stagger`
(**0.2**). All are hardcoded constants in `DotMatrixTransitionStyle` (LunaDesignSystem).
Global — every pixel-wipe (nav/modal/crossfade/reader mode-switch) shares it.

### THE RULE: only changed REGIONS animate — UIVIEW-level, never pixel-by-pixel

A wipe must dissolve **only the screen regions that actually change**. Genuinely-unchanged
chrome must stay perfectly static — it must NOT sit inside a full-screen snapshot and get
pixelated mid-dissolve. The canonical case: in the RabbitHole stacked reader, pushing/popping
layer 2 leaves layer-0's top/bottom **lips** unchanged, so they must not animate.

Diffing is at the **UIVIEW level (region/rect-based), not pixel-by-pixel**. The shared
mechanism is **`DotMatrixRegion`** (`LunaTransitions/DotMatrixRegion.swift`):

- `DotMatrixRegion.Item(id:frame:state:)` — one identified participant: an `id` (ties the
  same logical view across before/after), a `frame` (host coordinate space), and an opaque
  `state` token (any non-geometric change that should still wipe, e.g. a layer's role).
- `DotMatrixRegion.changedRegion(before:after:in:) -> CGRect?` — the union (bounding rect)
  of every changed sub-rect. An item is *changed* iff (keyed by `id`) it appears on only one
  side, or its `frame` OR `state` differs; both its before+after frames join the union.
  Identical items are excluded. `in:` clamps to bounds. nil ⇒ nothing changed.
- `DotMatrixRegion.isFullScreen(_:bounds:slack:)` — true when the region spans the whole
  bounds; callers then take the plain full-screen path (confining to the whole screen buys
  nothing and risks rounding seams).

### Region-confined transition API (reused by filter + mode-switch animations)

All paths take an optional **`region`** (in the host's coordinate space; nil ⇒ full bounds,
behaviour identical to before). When set, the overlay is framed to that sub-rect and the
before/after snapshots capture only that rect (via a translated context — see
`DotMatrixSnapshot.image(of:region:afterScreenUpdates:)`), so everything outside keeps its
live views and never pixelates.

- `DotMatrixCrossfade.run(in:direction:duration:region:changes:completion:)`
- `RabbitHoleTransitioning.play(prepare:in:region:completion:)` and
  `begin(before:after:in:region:)` (full-screen convenience overloads without `region:`
  forward to these in a protocol extension).

`RabbitHoleReaderViewController` computes the region from a `RabbitHoleLayout`-driven diff
(`placementItems` → `changedRegion`) before each dive/pop/overscroll: each layer's
`(cardFrame, role)` becomes an `Item`; unchanged layers (the layer-0 lip) are excluded.
`runTransition`/`snapshot` then capture only that rect. Full-screen changes (e.g. a
single-ancestor pop) fall through to the full dissolve unchanged. Metal-unavailable ⇒ instant
cut, as before. Tests: `DotMatrixRegionTests` (union math + the layer-2 push/pop lip exclusion).

## Testing notes

- The effect itself can't be exercised in the simulator via UI automation: the
  media picker is `PHPickerViewController` (out-of-process, untappable via
  injection). Pick media by hand on device/TestFlight.
- Top nav-bar bar-button items are flaky to tap via Blitz injection; content-area
  taps work normally.
- Archive/TestFlight with stable Xcode 26.2 (Xcode 27 beta swiftc crashes
  optimizing SwiftSoup). Build numbers run ahead of the pbxproj — check
  `asc builds list --app 6778648023` first.
