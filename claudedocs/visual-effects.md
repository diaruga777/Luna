# Visual effects

Luna uses ordinary UIKit presentation, navigation, and content-change animations. The
shared custom effects are the night-sky starfield, the loading indicator,
moon-horizon download progress, and the eclipse transitions.

## Appearance palette

`LunaColors` in `LunaDesignSystem` is the semantic palette shared by all four apps and
their extensions. **Both appearances are night.** Dark mode is white text on a true-black
base. Light mode is the **predawn** theme: the same near-black sky lifted one barely
perceptible notch (mean channel 0.055 against dark mode's 0.000 — `#0E0E0F` for the
central app) and given a faint chromatic cast. It is not a light theme and never carries
dark-on-light text; the two appearances differ only by that lift and cast, so "Light"
reads as the sky a few minutes before sunrise rather than as a different app. Nested
surfaces (cards, grouped content, `ReaderDepth`'s reader levels) step up in both ramps,
with each predawn level a notch above its dark twin.

The cast comes from `LunaSurfacePalette.predawnSurface(level:)`: the app's own
`atmosphereTint` cooled 60% toward a deep pre-sunrise blue, normalised to unit mean, and
pulled 55% back toward neutral, then scaled to `level`. So brightness is controlled purely
by `level` and no app's hue ever shouts. The central Luna app's tint is **white**, making
its sky achromatic moonlight — the neutral parent of the three coloured children (Reader
cool, Downloader warm, Price Tracker faintly teal).

### The sky travels on `LunaSkyTrait`, not `userInterfaceStyle`

`userInterfaceStyle` is pinned to **`.dark` app-wide** and the chosen appearance rides a
custom trait (`LunaSky`: `.night` / `.predawn`). This is not incidental: UIKit's own
surfaces — Liquid Glass, blur effects, alerts and action sheets, keyboards, scroll
indicators, text selection — key off the style and render *light* under a light trait. A
light-mode glass bar came out white carrying near-white Luna text. Pinning the style fixes
all of those at once, and as a bonus every implicit `.label` / `.placeholderText` /
`UIListContentConfiguration` default now resolves to its dark (light-on-dark) variant.

Consequences to remember:

- `LunaSkyTrait.affectsColorAppearance` is true, so dynamic colours re-resolve on a sky
  change exactly as they would on a style change — the in-app appearance switch still
  repaints a live hierarchy instead of rebuilding it.
- Views that cache resolved `CGColor`s must `registerForTraitChanges([LunaSkyTrait.self])`.
  **A `UITraitUserInterfaceStyle` change will never arrive again.**
- `.system` follows the device through the window **scene**, since the pinned window can no
  longer report the device style (`AppearanceSettings.followSystemStyle(of:)`).
- `AppearanceSettings.apply(to:)` has a `UIWindow` form for the apps and a
  `UIViewController` form for surfaces that render in someone else's window — the share and
  action extensions (via `ShareViewController`) and both App Clips.
- Anything rendering Luna colours onto a non-Luna surface must resolve them explicitly.
  The emailed price graph (`PriceGraphEmailSnapshot`) resolves against a plain dark trait
  collection so background and labels agree.

App UI must use `LunaColors` instead of UIKit's label/background/grouped/fill/separator
semantic colors. `AppearanceSettings` also installs matching appearances for UIKit-owned
table, collection, text-input, navigation-bar, and tab-bar surfaces before each scene
builds its root controller.

## Starfield (`StarfieldView`)

`LunaLibraries/Sources/LunaDesignSystem/StarfieldView.swift` puts an extremely faint
scatter of stars behind the card decks (`ArticleCardsViewController`,
`SavedMediaCardsViewController`) and the reading list (as `tableView.backgroundView`).

Quiet, but not invisible: the brightest star sits at ~20% alpha and most are under 8%, so
the background still reads as black and the stars stay something you notice rather than
something you're shown. **Nothing animates** — a twinkle would announce the effect and
defeat the point.

The card decks hand their starfield to the carousel as `chromeBackdrop`, so it counts as
carousel chrome: it fades out with the scrub strip and side cards when a reader takes over
the screen, and fades back in with them, inside the same 0.32s ease-in-out animation block
(`applyImmersionLayout`) so the timing matches for free. The reference is weak — the host
still owns the view. The reading list has no immersion and keeps its stars up.

The sky is *fixed*: 170 positions come from one deterministic seeded table in normalised
coordinates, so every screen and every app shows the same constellations and a rotation or
resize never reshuffles them. Brightness follows a cubed roll, so faint stars vastly
outnumber bright ones as in a real magnitude distribution; every 19th star also gets a soft
bloom. Stars carry the app's `atmosphereTint` washed 55% toward white — present as a cast,
still starlight. The central app's sky is plain moonlight.

## App launch fade

All four Luna apps use the production card and corona as their launch surface.
Their static `LunaLaunchScreen.storyboard` contains one opaque standalone PNG
recorded from the same fixed star table, `EclipseCoronaView`, and blank black
`CardSurfaceView` used by the first live frame. The corona intentionally omits
colored solar prominences. Keeping the composite outside
the asset catalog makes it available to the launch-snapshot process before the
app has started. The card is already the destination root card's full resting
size; the corona crops beyond the display instead of making the card smaller.
No content or app chrome is present. `AppLaunchTransition` asks the destination
carousel for its exact frame, guarantees the eclipse one 0.10-second visible
beat, and fades the splash away as one layer over 0.20 seconds. This avoids a
warm launch committing only the final transparent frame while remaining far
shorter than the former staged egress. There is no resize or multi-stage
egress. This happens on every launch, not only onboarding, and each
`KindWiring` composition root installs the shared transition. An incomplete
first run constructs a separate static UIKit instance of the same peak corona
behind the intro card before this fade, keeping it stationary after the splash
layer is discarded. It does not retain the splash raster or overlay hierarchy.
Completed roots preserve the ordinary fade-away behavior.

See `reader-onboarding.md` for the source-of-truth renderer, launch-art
regeneration command, first-run sequence, and visual validation flags.

## Onboarding Safari/Messages/card loop

The initial onboarding card retains the launch corona until “Show me how” is
pressed. The card-to-browser demonstration itself deliberately does not use an
eclipse: the button removes that corona, grows the intro card to the screen
edges, and crossfades its content into the local Safari facsimile. The second
source is a mock
iMessage thread with Johnny Appleseed: earlier messages in both directions are
grey gradient blocks and the newest incoming bubble contains Safari's current
mock URL. A tall solid-black deformation first stretches from the screen edge
into the same narrow, flat-sided bulge as the system Action Button response,
centered at the button's physical height. The bulge and the first, thick
displacement-only wave begin simultaneously; that wave finishes without
replacing any content. A second wave then creeps in from the display edges,
closing in on the highlighted Safari URL bar or iMessage link bubble and
turning everything behind its inward front black while leaving that element
visible. Once it finishes, there is no third wave: the whole isolated-link
frame simply crossfades into the target app's complete production root at its
exact centered card state, including its normal card chrome and carousel. The
live hierarchy is committed beneath the final composited frame.
The first Safari → save → iMessage → save loop completes before the final saved
state remains clear for a reading beat and the instruction scrim/content fade
appear separately. Later loops keep the same alternation behind the overlay and
replay the press, highlight, wave, and save transformation—not geometry alone.
Completion settles on the card and performs a short stationary crossfade into
the completed root card.

## Loading spinner (`DotMatrixSpinnerView`)

`LunaLibraries/Sources/LunaDesignSystem/DotMatrixSpinnerView.swift` is the shared loading
indicator: a configurable grid of rounded dots whose opacity and scale ripple diagonally.
It is a plain UIKit/Core Animation view with the familiar `startAnimating()`,
`stopAnimating()`, and `hidesWhenStopped` API. The email login cover can resolve its grid
into a checkmark after successful verification.

## Moon-horizon progress (`MoonHorizonProgressBar` / `MoonHorizonProgressView`)

`LunaLibraries/Sources/LunaDesignSystem/MoonHorizonProgress.swift` is the shared
determinate download-progress treatment. A bright point leads a thin illuminated line
along a curved horizon, with an optional activity pulse while progress is in flight.
`MoonHorizonProgressBar` is the UIKit renderer and `MoonHorizonProgressView` is the
SwiftUI/WidgetKit renderer. Both honor Reduce Motion.

The effect is used by Downloader progress surfaces including the Live Activity, action
extension saved-media screen, reading-list status pill, and Downloader App Clip.
Download surfaces show the traveling activity pulse. Playback uses of the UIKit bar
(the audio mini-player and video scrub overlay) disable it, leaving only determinate
progress and its head point.

## Lunar Eclipse navigation

When Reduce Motion is off, a native reader opened from a real Reader list row always uses
`LunarEclipseTransition`; its corresponding pop uses the reverse treatment. There is no
Luna-specific switch. Reduce Motion disables the effect. Search, deep links, Downloader,
Price Tracker, modals, and reader-internal navigation retain their standard animations.

`LunarEclipseNavigationDelegate` installs the navigation delegate and
`LunarEclipseTransitionCenter` carries the source-row context into the animator. The
animation silhouettes the source while a scene-wide veil darkens, moves the eclipse to
zenith under a corona, swaps the screen beneath the opaque frame, and uncovers the reader.
The reverse crosses the screen back to the originating row. Simulator builds use a longer
duration for visual tuning; device builds use production timing.

## The corona (`EclipseCorona`)

All three eclipse transitions — `CardEclipseAnimator` (carousel paging),
`InlineReaderEclipseTransition`, and `LunarEclipseTransition` — share one corona renderer,
`LunaLibraries/Sources/LunaDesignSystem/EclipseCorona.swift`. It is modelled on what a
camera records at totality rather than on a soft glow:

- **Chromosphere.** A hairline of near-white, slightly warm light sitting exactly on the
  limb. The single strongest "real photograph" cue: a blur has no hard inner edge, a real
  corona does. Achieved by clipping away the silhouette interior so only the outer half of
  the stroke survives.
- **Power-law falloff.** Concentric offset curves of the silhouette weighted by
  `(1 + d/d₀)^-n`, so the corona is bright and tight at the limb yet still faintly alive
  two radii out. A layer shadow's Gaussian profile dies far too abruptly and read as a lamp
  behind the card.
- **Streamers.** 26 uneven rays, long and bright near the equator and short fine brushes
  over the poles, each fanned into raised-cosine slices with jittered tips. Slices must
  **abut exactly** — overlapping them screen-blends into a bright seam down every ray — and
  each slice runs its gradient from the silhouette *centre*, so the discarded interior
  absorbs the ramp-up and no arc appears where the gradient began.
- **Pearl, not white.** Warm-white at the limb cooling to faint blue outward, with 22% of
  the app's `atmosphereTint` mixed into the outer corona (a no-op for the central app).

The full-screen (interior) variant, for a source that already fills the transition
container, is four trapezoid-clipped edge gradients — each clipped to the points nearer its
edge than any other, so brightness is a function of distance to the nearest edge and the
bands agree along every diagonal. Nested rounded-rect strokes (the obvious alternative)
offset by √2 more at the corners and read as a bevelled picture frame.

### Cost and prewarming

Rendering is hundreds of stroked curves plus a gradient per ray slice, far too much for a
`draw(_:)` on every frame, so each geometry is baked into a cached `UIImage`.

Core Graphics defers rasterisation to image creation, so the cost tracks pixel count almost
exactly — the drawing block itself measures ~13 ms while `renderer.image {}` took ~190 ms at
2x. The raster therefore runs at **1x** (~100 ms for a card, and the upscale is invisible on
passes this smooth), and the one detail that needs real resolution — the chromosphere
hairline — is a vector `CAShapeLayer` in `EclipseCoronaView` instead of part of the image.
`preferredRange` makes no difference; don't bother with it.

100 ms is still several dropped frames, so nothing waits for the first transition to ask:
`EclipseCorona.prewarm(bodySize:cornerRadius:tint:)` renders on a background queue and hops
back to the main thread to store. `renderExterior` is deliberately free of UIKit state so it
can — `UIGraphicsImageRenderer`'s block form keeps its context thread-local, and every colour
in the pass is static rather than a dynamic `UIColor` needing trait resolution.

Two geometries get prewarmed, both as soon as they are known and both idempotent, so calling
them from every layout pass is fine:

| Geometry | Prewarmed from |
| --- | --- |
| the centered card (paging transitions) | `CardCarouselViewController.viewDidLayoutSubviews` |
| the card minus the 42pt tab strip (inline reader) | `SplitWebOverlayViewController.prewarmEclipseCorona(cardFrameInWindow:)`, called from the reader card's `viewDidLayoutSubviews` |

Verified on a real launch: the prewarm starts ~130 ms in and completes before any transition,
with no synchronous miss. `EclipseCoronaPrewarmTests` guards the contract — in particular that
the prewarm key matches what the transition asks for, since a mismatch silently does the work
twice and the hitch comes back. The interior corona (~3 ms) and the flare (~1.5 ms) are cheap
enough to leave alone.

The diamond-ring point (`EclipseFlareView`) matches: a blown-out warm core drifting to a
cool flare tail, irregular spike lengths rotated off the axes, and a faint lens ghost ring.

`EclipsePreviewRecorderTests` renders the corona, the interior corona, the flare, and the
starfield to PNGs for tuning. It is skipped unless `RECORD_ECLIPSE_PREVIEWS=1` and
`ECLIPSE_PREVIEW_DIR` are set — and as with snapshot recording, those must be passed with
the `TEST_RUNNER_` prefix to reach the runner's environment.

## Testing notes

- Top navigation-bar items can be flaky to tap through simulator automation; content-area
  taps are more reliable.
- Archive/TestFlight with stable Xcode 26.2. Check the latest App Store Connect build
  number before uploading a new archive.
