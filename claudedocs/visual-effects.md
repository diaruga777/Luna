# Visual Effects — Dot Matrix pixel-wipe transitions, spinner, keyboard reveal

Luna's shipping GPU visual effects are the **Dot Matrix pixel-wipe transition engine**
(a Metal two-wave dissolve used for nav/modal/crossfade/reader transitions and the
keyboard reveal) and the **Dot Matrix loading spinner**. All of it is driven from
`LunaContentRendering` (the Metal engine) and `LunaTransitions` (the UIKit facade), with
the spinner in `LunaDesignSystem`.

## Loading spinner (`DotMatrixSpinnerView`)

`LunaLibraries/Sources/LunaDesignSystem/DotMatrixSpinnerView.swift` is the shared
loading indicator: a small self-animating grid of dots (configurable `dimension` /
`side`). It is a plain UIKit/Core Animation view — no Metal — and is used app-wide
wherever an in-progress spinner is shown.

## Onboarding dot-matrix views (`LunaSocialUI`)

Onboarding extends the motif through its push/pop pixel-wipe transitions and exit
`DotMatrixCrossfade`, plus two Core-Animation-only views (same technique as the
spinner — per-dot `CALayer` + `CAKeyframeAnimation`, no Metal, model layers stay
static so `layer.render(in:)` snapshots are deterministic):

- **`OnboardingDotMatrixBackdrop`** — an ambient panel of dots
  (`DotMatrixTransitionStyle` geometry ×2) behind every step's icon/illustration,
  with a slow diagonal shimmer sweep. Static at resting opacity under Reduce Motion.
- **`OnboardingDotMatrixProgressView`** — "step X of Y" as a dot row pinned above
  the scroll area: completed/current dots filled in the reading accent (current one
  pulses; frozen under Reduce Motion), upcoming dots dimmed. Step index/total is
  threaded from `OnboardingFlow` (3 steps: email, Safari extension, and either
  action extension or iOS 27+ Action Button setup).
- **`OnboardingAnimationView`** — fixed-size setup illustrations. The nested
  UIKit illustration tree is built lazily on `start()` after the step appears, so
  navigation pushes do not block on constructing the in-page animation.

## Moon-horizon progress bar (`MoonHorizonProgressBar` / `MoonHorizonProgressView`)

`LunaLibraries/Sources/LunaDesignSystem/MoonHorizonProgress.swift` is the shared
determinate progress treatment: a full-width, very slightly curved lunar horizon.
Sunlight creeps along it left→right — a bright sun point marks the head, a thin warm
line of illumination trails it, the horizon ahead stays dark (a barely-there line).
`MoonHorizonStyle` holds the shared quad-Bézier geometry + dynamic palette (pale gold
on dark, deeper amber on light). Two renderers over the same geometry:
`MoonHorizonProgressBar` (UIKit, CAShapeLayers, `setProgress(_:animated:)`) and
`MoonHorizonProgressView` (SwiftUI, plain `Shape`s so WidgetKit renders it). Used by
every download progress bar: the Downloader Live Activity (lock screen + Dynamic
Island bottom region), the action extension's saved-media screen, the reading list's
bottom status pill, and the Downloader App Clip.

**Activity pulse.** While progress is mid-flight (fraction in
(`pulseMinimumFraction`, 1)), a dimmer point of light — the sun point at its former
brightness (`pulseBloom*Alpha`; the head itself was brightened a step to
`headBloom*Alpha` when this landed) — periodically sweeps in from the left edge
along the lit stretch and merges with the head in a brief flare brighter than
either alone. Cadence/durations live on `MoonHorizonStyle` (`pulseCycleDuration`
2.6 s, `pulseTravelDuration` 1.1 s, `pulseFlareDuration`). UIKit: a repeating
`Timer` started/stopped in `didMoveToWindow` fires `CAKeyframeAnimation`s along a
de Casteljau-trimmed horizon path (`horizonPath(toFraction:in:)`); the flare is
scheduled separately so it lands on wherever the head actually is by merge time.
SwiftUI: a repeating `keyframeAnimator` — time-driven, so WidgetKit's frozen Live
Activity renders just show the initial (invisible) phase; no pulse there, by
design. Both renderers skip the pulse under Reduce Motion.

## Dot Matrix pixel-wipe TRANSITIONS (the facade) — region-confined wipes

The **`LunaTransitions`** library wraps the
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
`animatedTransitionsEnabled`. Luna Reader additionally exposes an off-by-default
**Lunar Eclipse Transition** toggle. When enabled (and Reduce Motion is off), it replaces
the Dot Matrix navigation wipe only for a native-reader push started by tapping a Reader
list row, and for that reader's corresponding pop. `LunarEclipseTransition` snapshots the
source row into a slightly undersized black silhouette, dims the scene, moves the eclipse
to zenith under a directional white corona, then flashes and uncovers the destination;
the pop mirrors it from right-to-left with the bright point on the left. It never affects
Downloader, Price Tracker, search/deep-link opens, reader-internal RabbitHole transitions,
or any other navigation/modal transition. DEBUG builds accept
`-lunarEclipseSlowMotion` to multiply the same timing by five for visual tuning.

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

- **Partial-screen present**: the *region wipe* starts FIRST — the two-wave dissolve
  confined to the modal's pixel-aligned frame and clipped to its platter's rounded
  corners (`cornerAttributes` walks the platter for the real radius/maskedCorners),
  from the old screen's region pixels (identical to the cover beneath, so the overlay
  appears seamlessly) to the committed modal — because everything before its first
  frame reads as tap latency. The *chrome fade* runs alongside: everything outside
  the frame (dimming, sheet stack-back) crossfades to the modal-free background,
  captured by briefly hiding the presentation's chrome view under the cover, never
  pixelating. Dismiss mirrors it (wipe first, then un-dim fade). A final 0.06s cover
  fade over the live UI softens anything snapshots can't know (shadows, mid-wipe
  motion).
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
one is up (`DotMatrixKeyboardReveal.activeCover`), else the live window. A plain
snapshot view holds those pixels until the Metal layer has painted its progress-0
frame, so a missing first drawable cannot expose a bare keyboard. The keyboard rises
invisibly beneath it, and on `keyboardDidShow` the Metal patch dissolves out in
0.15s (bottom-to-top wave). A keyboard rising during a `DotMatrixModal` present (a
modal text field auto-focusing) instead holds under its patch until
`modalWipeDidStart()` so its dots run in step with the modal's wipe (1s fallback if
the choreography bails). Frame CHANGES while visible, hardware-keyboard bars
and floating iPad keyboards are ignored; a hide mid-reveal tears down instantly.
Installed once in AppDelegate via `DotMatrixKeyboardReveal.install(windowProvider:)`
(a closure, so the library stays extension-safe), which also schedules
`prewarmKeyboard()` ~1s post-launch to pay the process's one-time keyboard bring-up
cost off any tap path.

### First-transition warmup

`SceneDelegate.installDotMatrixTransitions()` calls
`DotMatrixTransitionCenter.prewarm(in:)` once the root window exists. Prewarm does more
than build and park a `RabbitHoleTransitionView`: it briefly attaches the overlay to
the real window, uploads a tiny texture pair, lays out its `CAMetalLayer`, requests a
drawable, and commits a tiny first render before parking it. That keeps the first
user-visible dotmatrix transition from paying Metal/layer/drawable first-use costs on
the tap path; later transitions reuse the warmed parked overlay as before.

**Intentional exclusions**: toasts, spinners, gesture snap-backs and other
micro-interactions per the rule below.

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

- Top nav-bar bar-button items are flaky to tap via Blitz injection; content-area
  taps work normally.
- Archive/TestFlight with stable Xcode 26.2 (Xcode 27 beta swiftc crashes
  optimizing SwiftSoup). Build numbers run ahead of the pbxproj — check
  `asc builds list --app 6778648023` first.
