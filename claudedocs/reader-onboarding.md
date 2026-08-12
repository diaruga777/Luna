# Luna launch and setup lessons

Luna no longer has a standalone onboarding screen or onboarding-only carousel.
Every app launches its production card deck immediately. The permanent util card
at index zero owns first-run copy and the entry points into setup; its full state
and layout contract are documented in `util-card.md`.

This document covers the launch transition, completion model, and the native
Safari and Action Button shortcut lessons that the util card reuses.

Central Luna borrows sibling lessons in product rank order: Reader, Downloader,
then Price Tracker. It starts with the highest-ranked sibling whose installation
marker is absent. The central Messages lesson uses that sibling's practice or
weekly link and save surface while keeping Luna's name and icon. The Manage
Extensions sheet remains branded Luna, and the Safari prompt states that all Luna
apps' features apply.

### The central Safari lesson is all three, and it does not stop

Central Luna is the app whose every surface takes every kind, so its Safari
lesson is not one sibling's — it plays ALL THREE, in that rank order, and then
keeps playing them.

One replica per sibling is mounted hidden (`safariReplicas`), each built from the
central configuration with that sibling's `demonstrationApp`, so each carries its
own mock page, mock URL and lesson: the Reader's buried explainer and its clutter
wipe, the Downloader's blocked post and video panel, the Price Tracker's product
page, seller pill and spotlight. Nothing new is authored for the central app.

The hand-over runs off ONE signal. Every lesson ends by asking for the same
thing, so each reports reaching its own ask —
`SafariReplicaViewController.onDidReachSetupOffer`, raised once per run from the
explainer's `cleanUpClutter` completion, the video panel's own arrival (once the
clip has started), or the product card's arrival. The first lesson alone shows
Safari's Manage Extensions sheet. The host then holds
(`OnboardingDemoLoopTiming.siblingLessonHoldDuration`, 2.0s), cross-fades to the
next replica, rewinds it and begins the post-sheet result directly. Every pass
after the first runs at 70% of the original timeline. It never has to know which
lesson it is playing. **The signal is what makes the cycle exist**: it used to hang off
`onActionButtonWaveFinished`, which no Safari lesson ever fires, so the central
app played one sibling and stopped.

**Every lesson in every app now ends on the SAME popup**,
`OnboardingSafariSetupPopupView` (`Luna/Reader/Onboarding/
OnboardingSafariSetupPopupView.swift`): a minimal "Set up in Safari" / "Skip"
card — nothing else, no title, no steps, no border corona of its own — over a
scrim light enough to keep whatever is running underneath it legible. Only
the "Set up in Safari" button wears a corona (plus its attention pulse); the
card is plain so the glow reads as pointing at the one actionable thing
rather than the whole popup. It replaces THREE different former endings: the explainer page's own
inline steps-and-buttons block, the video panel's grow-a-chin-of-enable-steps
beat, and the price lesson's `OnboardingSafariSetupCardView`. The step-by-step
instructions those used to print now live on the hosted setup web page the
popup's prominent button opens; the popup itself is presented by
`AppOnboardingViewController.showSafariSetupPopup()`, window-hosted exactly
like the older `DemoInstructionOverlay`-based asks.

**The popup and its scrim are owned by `AppOnboardingViewController` itself,
not by any `SafariReplicaViewController`.** They used to be raised (and
window-hosted) by whichever replica was on screen when the lesson reached its
own setup offer — documented, at the time, as deliberately fine because both
were mounted on the window rather than inside that replica's own view, so
hiding the replica during a later cross-sibling swap couldn't touch them.
That reasoning covered the REPLICA'S OWN VIEW being hidden; it did not cover
the replica OBJECT itself no longer being `safariReplica` — central Luna's
cycle reassigns that property to a different sibling on every swap, so an
owner that is a specific replica instance is an owner that gets swapped away
from being "current" while still nominally holding the popup. In practice a
cross-sibling swap could tear the scrim down while the popup card stayed (the
scrim and the popup's activate-button corona rebuild are both driven off the
same geometry-change machinery the swap disturbs) — the exact split-ownership trap
this section already warned about for the older `DemoInstructionOverlay`
design. Moving both onto `AppOnboardingViewController` — the one object that
runs every swap and therefore outlives all of them — removes the trap
structurally instead of patching around it: `showSafariSetupPopup()`,
`dismissSharedSafariSetupPopup(animated:completion:)` and
`restoreSharedSafariSetupPopupIfNeeded()` are its methods now, and
`SafariReplicaViewController` keeps only its OWN per-lesson
`instructionOverlay` (the Safari prompt, the shortcut/Action Button ask, the
external-open failure — asks that belong to a single lesson, never cycled
under). `hasSafariInstructions` checks the host's own `safariSetupPopup` OR
any replica's `hasInstructions`, so it still answers correctly for both.

The full-screen scrim is a distinct type, `SafariSetupScrimView`, that
`showSafariSetupPopup()` mounts directly on the window, ADDED BEFORE the popup
rather than carried inside it — deliberately: the popup's own activate-button
corona rebuilds itself on geometry changes
(`OnboardingSafariSetupPopupView.layOutActivateCorona`), and the card carries
none of its own to disturb anything either way. Keeping the scrim completely
outside the view that does this rebuilding means nothing about that logic —
correct or not — can ever affect whether the scrim stays visible; being a
named type rather than a bare `UIView` is what lets a test find and count it
precisely
(`ReaderOnboardingTests.testCentralSafariLessonKeepsExactlyOneScrimAcrossASwap`).
Its alpha is 0.65 (`OnboardingSafariSetupPopupView.scrimAlpha`).

The compass button (`OnboardingSafariSetupActionButton`) reuses
`GlassStyle.actionButtonConfiguration`'s capsule for the "Set up in Safari"
label and `OnboardingSafariCompassGlyph.image(side:)`'s hand-drawn compass
(radial-gradient dial, tick marks, a red/white needle at 45°) as its leading
image, with `OnboardingExternalLinkGlyph.image(side:)`'s hand-drawn "this
leaves the app" mark — a rounded square with its top-right corner left open
and an arrowhead poking out through that opening — laid out as a separate
trailing image view (`UIButton.Configuration` only carries one image, and
this button needs two, in different roles), tucked close to the label and
raised a few points above its vertical center. Never SF Symbol's
`arrow.up.forward.square`: that glyph fully encloses its arrow, which reads
wrong for a mark whose entire point is "this goes somewhere else."

`safariLessonDidReachSetupOffer` now fires this same "last lesson of the first
cycle raises the popup, everything else is just the next beat" logic for EVERY
app, not only central Luna with multiple siblings: a faceted app's
`safariDemonstrationApps` has exactly one entry, so its own single ending
trivially satisfies "last lesson of the first cycle," and the popup comes up on
that app's very first pass through its lesson. From there the SAME forever-loop
that cycles central Luna's three siblings underneath the popup also covers a
faceted app — `cycleSafariInstructionLesson`'s fallback (`apps.count <= 1`) just
resets and replays the one lesson in place rather than cross-fading to a sibling.
So "the lesson resets and replays under the popup, forever, until answered" is
one mechanism for all four apps, not a central-only behavior with a faceted
special case.

Re-entering the lesson rewinds to the first sibling. An external hop stops the
cycle (`pauseDemoPresentationPlayback`), and a Safari return with no extension
evidence calls `restoreSharedSafariSetupPopupIfNeeded()` once (the popup is the
host's own state, so there is exactly one place to restore it) — which
re-enables the popup's buttons and re-applies its attention pulse — plus each
replica's own `resumeVideoLessonAfterExternalReturn()` (a replica's video
lesson, if it has one, still isn't necessarily the one currently on screen),
then resumes the loop (`resumeSafariLessonLoopIfNeeded`).

## Launch root

Each `KindWiring.makeRootViewController()` always creates that surface's normal
cards controller. It never conditionally returns `AppOnboardingViewController`.

The util card state is captured when `CardCarouselHostViewController` is
constructed:

- incomplete: animated headline, weekly save, two setup actions, paste;
- complete: weekly save, matching recent URLs, paste.

The state intentionally does not switch in-place after the second setup leg.
Buttons may become checked/disabled, but the compact completed layout appears on
the next process launch. With any saved cards present, launch centers the first
save at index one; only an empty store starts on the util card.

On the central util card, the Safari and shortcut labels cycle through the
Reader, Downloader, and Price Tracker labels in that same rank order. The
buttons themselves stay fixed; only their clipped labels translate and fade.
The labels and Save of the Week use one four-second clock, so their changes
start together. The central row cycles those three kinds in rank order; a
missing kind is a fully empty turn, not a blank card.

## Launch artwork and reveal

`LunaLaunchScreen.storyboard` renders the static black card, glass rim,
`EclipseCorona`, and starfield. `AppLaunchTransitionTarget` asks the production
deck for its real resting frame, holds the launch layer briefly, and crossfades
into the laid-out deck. There is no onboarding-root swap after the reveal.

**The storyboard is CONSTRAINTS over two rasters, not one composite.** It used to
be a single 402×874 image pinned to all four edges with `scaleToFill`, so the
card inside it was the right size on the recorder's phone and a non-uniform
stretch of it everywhere else. It now reproduces `CardDeckGeometry` in Interface
Builder constants — safe area + 48pt clearance, 104pt strip runway, the largest
exact-9:16 card centered in what is left, capped at half the width on a
regular-width screen — and scales the corona artwork to `1.84 ×` that card's
width. `LaunchScreenGeometryTests` loads the storyboard at six screen sizes and
checks both frames against the Swift geometry, which is the only thing keeping
IB constants and Swift constants in step.

Two single-scale rasters, loose in the bundle (the launch screen needs them
before the app has started) rather than in the asset catalog, and single-scale so
one generously-sized file downscales to every device instead of a 2× variant
being upscaled on the largest iPad:

| Asset | Canvas |
| --- | --- |
| `LunaLaunchStarfield.png` | the whole reference screen; drawn `scaleToFill` so stars land where the live `AppLaunchStarfieldView` (which places them at fractions of its bounds) puts them |
| `LunaLaunchCoronaCard.png` | exactly `AppLaunchGeometry.coronaFrame` — the card grown by `0.42 × cardWidth` on all sides — holding the corona, the black card body and its rim |

The corona's throw is a fixed FRACTION of the card width here
(`AppLaunchGeometry.coronaReachFraction`) rather than `EclipseCorona.reach`'s
clamped formula: a ratio that changes with the card size cannot be carried by one
uniformly scaled raster. On a phone the clamp does not bind, so the throw is
unchanged.

`AppLaunchTransition` draws the SAME two rasters in the app's first live frame,
and onboarding's intro corona and the util card's corona draw the corona raster
too, so all four surfaces are identical by construction rather than by agreement
— and none of them re-renders a corona at launch (~80ms each at 1× on a
simulator, three times over).

To re-record after intentional corona/rim/star changes, run
`ReaderLaunchArtRecorderTests.testRecordReaderLaunchArtworkWhenRequested` with
`TEST_RUNNER_READER_LAUNCH_ART_DIR=<output directory>`, then copy both PNGs into
`Luna/`.

## Surface headlines

One sentence in two beats, in EVERY app: a headline is an initial state and a
final one (`OnboardingStrings.Intro.headlineInitial` / `headlineFinal`), and the
second beat animates the difference between them.

| App | Initial | Final | Anchor that never moves |
|---|---|---|---|
| Reader | “Read.” | “Read more.” | `Read` |
| Luna | “All your Luna apps.” | “One Luna app.” | ` Luna app` |
| Downloader | “Watch and download.” | “Watch and download.<br>Without signing in.” | the whole first line |
| Price Tracker | “Get the best price.” | “Get the best price. Always.” | `Get the best price.` |

**A headline may be more than one LINE**, written with `\n` in the strings file
the way any other multi-line value is (`OnboardingIntroCopy.lines` splits both
states on it and pairs them up by position). The beats then play line by line,
and that is the whole of the mechanism — there is no second animation and no
second code path:

- The Downloader repeats its first line **verbatim** in the final state. Its two
  states are therefore identical, the anchor is the whole line, and the second
  beat has literally no operation to run on it: no reflow, no re-reveal, nothing
  to re-time. It simply stands.
- Its second line is absent from the initial text entirely, so that line's
  initial state is the empty string, its transition is a full replacement with
  nothing departing, and beat two brings it in under its own front.
- The view is `lineHeight × lines.count` tall from the moment it is built, so
  the arriving line lands in room that was always reserved for it. The first
  line's position does not depend on whether the second one has spoken yet.
- One font for the whole headline: the widest line decides the fitted size.
- The spoken label drops a line that says nothing in the beat rather than
  reading a blank one, so VoiceOver hears the sentence and not the layout.

`OnboardingHeadlineTransition` (pure text, `OnboardingHeadlineTransition.swift`)
finds the anchor: the LONGEST continuous run of characters both states carry,
ties going to the run that appears earliest in the final text. Everything before
it and everything after it belongs to one state or the other — whitespace,
punctuation and a letter changing case are ordinary characters here, which is
why “Miss a sale” → “Never miss a sale” keeps “iss a sale” and lets the capital
“M” leave with “Never m” arriving in its place.
Copy that shares no run worth standing still for — nothing in common, a single
character, or punctuation only — replaces itself outright (`isFullReplacement`),
each state centred on its own.

`OnboardingIntroHeadlineView` renders that in the two-beat moon-reveal: beat one
brings the initial sentence in whole; beat two blooms the arriving fragments in
and the departing ones out, in the same turn, and never touches the anchor. Two
consequences worth knowing before changing copy or layout:

On the launch that owns this reveal, the setup controls fade in after the final
headline beat as usual, but the weekly row stays hidden for a further three
seconds. The headline then fades away, the weekly row fades into the normal
completed-card seat (`weeklyTopRatio`), and only then is central Luna's shared
weekly/button cycle enabled. This keeps the opening sentence legible and avoids
movement behind the weekly row's entrance.

- **The FINAL sentence is what is centred.** The initial one is typeset wherever
  the anchor's final position puts it, so it lands left of centre when the copy
  grows on the right (Reader, Price Tracker) and right of centre when it grows
  on the left. Nothing translates between beats, because nothing was ever
  anywhere else. Each sentence is one composition with every character but the
  fragment's own in clear ink, so a fragment's position is real typesetting
  rather than a measured offset.
- **A narrow card shrinks the font, not the layout.** Both states have to fit
  side by side (`Metrics.unionWidth`), and on a multi-line headline the WIDEST
  line decides for all of them, so the view picks a size from 25pt down to a
  13pt floor at layout time and rebuilds its fragments if that size changes —
  which it will only do before a beat has begun.

Departures get their own fronts rather than sharing the arrivals'. A period's
ink sits a whole x-height below “more”'s, so one edge descending through the
shared frame would uncover the top of the “m” a third of a second before
reaching the period beside it — long enough to read the wrong sentence. Each
departing fragment's front starts advanced by the drop from the highest arriving
ink (`frontLead(forDeparting:onLine:)`), so it goes out as the arrivals come in
— measured against its OWN line, since a fragment a line below is not something
it has to leave with.

### The light is composited off the main thread

The glow is the expensive part of the whole animation, and it is expensive in a
way that cannot be arranged away: `GlyphPixelBloomView` builds an emitter (the
glyph raster clipped to the front's trailing bands) and then draws it eight times
under stacked Quartz shadows. Measured, that is **~5ms a frame for one short
fragment**, and it is almost all fixed cost per pass rather than blur width —
halving the area or the radii barely moves it, and merging passes changes the
look. A second beat blooms two fragments at once, so the old arrangement, which
drew in `draw(_:)`, spent ~10ms of every frame on the main thread before Core
Animation had committed anything. On a 60Hz simulator that measured **26.6ms
mean between display-link ticks with 55% of frames later than 20ms** — the
choppiness was real, and not a slow device.

A frame is now composited on a background queue and handed to a `CALayer` as
ready-made `contents` (`GlyphPixelBloomView.Pass`). The display link stays on the
main thread, because it has to sample the occluder's *presentation* transform to
keep the light on the mask edge, but it only asks for a frame; a tick arriving
while one is still in flight is dropped rather than queued. Same measurement
after: **16.67ms median, p99 16.67ms, one late tick in 371** — a locked 60Hz.

Two things are worth knowing before touching that renderer:

- **It is Core Graphics, not UIKit, and that is not a style choice.**
  `UIGraphicsImageRenderer` and `UIImage.draw(in:)` composite *nothing at all*
  off the main thread — no error, no warning, an empty buffer every frame and a
  light that simply never appears. Hence the hand-applied y-down flip and the
  `CGImage` draws.
- **The halo radii are POINTS and had to be converted.** A view's `draw(_:)`
  context carries its 2×/3× in the CTM, so `blur: 30` there means 30 points; a
  bitmap context measures a shadow's blur in DEVICE PIXELS however its transform
  is scaled afterwards. Miss the conversion and the white cores still land
  perfectly while every outer halo comes in at a third of its reach — the broad
  low-frequency wash that makes this read as sunrise disappears and the light
  goes hard. (The old invalidation rect's `-34` inset was in points for the same
  reason, which is where `glowReach` comes from.)

Equivalence was checked by freezing both the old and new drawing at the same
sweep phase and diffing the screens: a mean of 0.03 of one 255-level over the
headline, total light within 0.1%, and every other pixel identical.

The util card starts the animation from `cardDidBecomeCentered`, so it does not
spend it while mounted only as a side peek. On the launch that animates it, the
card's other elements wait at alpha 0 and fade in together, in place, from the
second beat's completion (`claudedocs/util-card.md`, "the headline speaks
first"); a non-animating appearance shows them immediately.

## Completion model

`AppOnboardingStore` persists an explicit completion marker and two per-app
handled markers: Safari and save setup. Setup evidence itself lives in
`LunaSetupStatusStore` and can be written by extensions/App Intents.

`isCompleted` is true when:

1. the app has an explicit completion marker; or
2. central Luna's Safari plus save evidence covers a newly installed facet; or
3. both this app's Safari and save legs are finished, where finished means real
   run evidence or completed/skipped handling.

Reader keeps its shipped `reader.onboarding.completed.v1` key. The other apps use
`<surface>.onboarding.completed.v1`. Central inheritance remains one-way: a new
facet can inherit a fully configured central Luna, while central Luna does not
inherit a facet's completion.

## Entering setup

The util card's two buttons call
`AppOnboardingViewController.presentSetupReplay`. AppDelegate injects that
launcher so the shared card does not own target composition.

The setup controller is now a transient lesson presenter, not the app root. It
uses the existing offline/native demonstrations:

- Safari runs ONE of three demonstrations, chosen by
  `OnboardingSurfaceConfiguration.safariLesson` (`OnboardingSafariLesson`). All
  three end in the same place — the shared `OnboardingSafariSetupPopupView`
  coming up above them — and differ only in what they show first. None of the
  three prints its own step-by-step instructions any more: that copy moved to
  the hosted setup web page, which the popup's prominent button opens.
  - `.extensionExplainer` — the native `luna.app` page, buried under ads and
    popups, then that app's own mock page (Reader `[.lunaPage]`, central all
    three). What the extension takes AWAY, told by the clearing wave below.
  - `.priceComparison` — the Price Tracker only, `[.amayzon]`: the product page
    itself, with the seller pill finding a better price on it (see "The price
    tracker demonstrates instead of explaining" below).
  - `.videoDownload` — the Downloader only, `[.instaTok]`: the blocked post,
    with the extension's video panel playing what the page would not (see "The
    Downloader's lesson" below).

  An app whose lesson is not the explainer builds no explainer page at all
  (`SafariReplicaViewController.lunaPage` is nil there). Either way it shows the
  extension effect, then guides the user to Safari extension setup. Leaving for
  real Safari stamps `setup.safari.setupTapAt.<app>` + that app's display name,
  which the extension pairs with its OWN first run to confirm setup in the page
  and invite the user back — see `claudedocs/safari-extension.md`'s "in-page
  setup confirmation".
- The hop into REAL Safari opens the RUNNING app's own hosted setup page —
  `https://luna-site-bm6.pages.dev/setup/<slug>` (`AppOnboardingViewController
  .openSafariSetup`, slug from the private `LunaApp.safariSetupPageSlug` beside
  it, matching `site/README.md`'s canonical slugs). The page IS the
  instructions now, so the hop lands the user on the very page that tells them
  what to tap next — there is no separate practice-page requirement to satisfy,
  since the destination is never Reader-eligible chrome to begin with.
- Save setup uses the Messages replica and there is exactly ONE of it: the
  Action Button shortcut journey. `OnboardingSaveSetupMode` answers
  `.actionButtonShortcut` or `.unavailable`, and a device that answers
  `.unavailable` is offered no save lesson at all — the util card omits the
  button, and that leg is finished by definition rather than falling back to a
  share-sheet demonstration. Its save is REAL — see below.
- external-open recovery overlays remain available if Safari, Shortcuts, or
  Settings rejects a route.
- Reduce Motion replaces waves and switcher choreography with short fades.

### The Safari explainer page is decoration now, not an explanation

`OnboardingSafariPageView` used to argue for the extension: a headline, a
byline, per-app prose, three enable steps each beside a picture of the exact
Safari chrome it named, and its own Activate Safari / Skip pair anchored above
the browser chrome. All of that instructional content moved to the hosted
setup web page, and what is left on the page is pure decoration — an app icon,
a lorem ipsum headline, and lorem ipsum body copy — dressed up to still read
as a plausible article once the wave reveals it. The byline, the steps and the
actions block are gone outright, not just re-worded.

The header still pins at `OnboardingSafariPageView.minimumTopInset`; the body
copy now just runs from below it down to the current bottom reserve
(`chromeReserve` while the mock browser bar is up, `clearedChromeReserve` once
`setReservesBrowserChrome` releases it for the wave). The body is still fitted
rather than fixed: `OnboardingStrings.Safari.mockParagraphs` is a
`ChunkedDefinition` — several lorem ipsum paragraphs, universal rather than
per-app since the furniture is now identical in every app — and the page
prints the largest cumulative prefix that fits (`fittedProse`), so a short
phone shows one paragraph and a tall iPad shows several, the way a real
article's copy would fill more or less of a taller page. There is no floor to
protect any more (no steps or actions to keep clear of): a container too short
even for paragraph one just truncates it.

The 17pt/lineSpacing-5 typography still lives once, in
`OnboardingSafariPageView.proseFont` / `proseLineSpacing` /
`proseHeight(of:width:)`. `MoonRevealLineView.setText` names the prose during
layout and returns early on unchanged text, which is what keeps a layout-time
text change from scheduling another layout pass.

### The Downloader's lesson is the blocked post, answered

Everything above about the explainer page is about a PAGE — clutter over prose,
and a wave that takes the clutter off. The Downloader would never act on that
page at all: its subject is the video ON a page, and a lesson that never showed
one was teaching the Reader's story to someone who came for videos. So its
browser loads exactly one thing, the bundled `InstaTok.html`, and the
demonstration is the extension doing its actual job.

It is the media sibling of the price lesson below and keeps its shape — mounted
with the browser, `begin` / `reset`, generation-guarded so a rewind cancels its
pending beats. Its own beats:

| beat | what is on screen |
| --- | --- |
| `pageHoldDuration` (3.2s) | the post alone: its video playing full-bleed behind the "Sign up to keep watching" wall that stops it |
| `presentDuration` (0.45s) | `OnboardingVideoDownloadOverlayView` arrives over it, and the clip starts in its stage |
| `playbackHoldDuration` (0.75s) | the video starts under a full-width "Download in Luna"; after a brief proof-of-playback beat, the panel reports its setup offer and stays exactly like this |

The blocked-post hold establishes the premise. The player only needs a short
proof-of-playback beat before the shared popup flow advances; the panel's former
third subject lives on the hosted setup page. The playback hold is counted from
the CLIP starting rather than from the panel finishing its arrival.

**The panel is a replica, not a stylisation.** Every measurement in it is read
straight off `presentVideoOverlay` in `LunaSafari/Resources/content.js` — the
`calc(100vw - 24px)` panel capped at 640 in
`NIGHT_SURFACE` at radius 20 with 10pt padding, the 34pt round close button over
an 8pt gap, the black stage at radius 12, the full-width capsule 10pt under it at
`minHeight: 44` in the media kind's tint (`LunaSurfacePalette.baseColor(for:
.downloader)`, which is what `KIND_TINTS.media` hand-copies). A change to either
one is a change to both, and `SafariVideoOverlayReplicaTests` pins the two
files' shared numbers and the shared string to each other — with ONE
deliberate exception: the stage's ASPECT. In Safari the stage takes the CLIP's
own shape, clamped between the extension's default 16:9 and the visible
viewport; this lesson's bundled clip is a portrait re-cut, so its stage is
9:16 (`OnboardingVideoDownloadOverlayView.stageAspect`) rather than matching
`content.js`'s 16:9 — a constant rather than something measured off the
`AVPlayerItem` asynchronously, so the panel's own layout never depends on an
asset load.

Three things about it that are NOT the web panel:

- **The backdrop is half the extension's weight, and the post never goes away.**
  `content.js` puts the panel over `rgba(0, 0, 0, 0.78)` and a 4px blur, which is
  right in Safari: you are the person who opened that page, and burying it is how
  the panel says "look here now". In the lesson that page is the QUESTION — the
  wall refusing you is the whole premise — so blacking it out the moment the
  answer arrives would show the user two unrelated screens. Both layers stay, so
  the panel still reads as something Luna put in front of the page, at
  `scrimAlpha` 0.34 and `backdropBlurAlpha` 0.45; the post plays on behind them
  for the whole demonstration.
  `testTheBlockedPostIsStillVisibleBehindThePanel` states the deviation against
  the extension's own value, so it fails if either side moves.
- **The stage letterboxes on the shortest phone.** The portrait stage's ideal
  height (`contentWidth × 16⁄9`) is taller than a 375×667 phone's panel budget,
  so the stage clamps down and the clip letterboxes rather than the panel
  overrunning the page — `testTheStageLetterboxesToFitOnTheShortestPhone`
  pins that the clamp engages and the panel still clears the mock browser bar.
- **Nothing in the panel answers a tap.** Not even an activate/skip pair any
  more: the close button, the download button and the player's controls have
  no target and no gesture recognizer, and the ask that used to live here now
  lives entirely on the shared, window-hosted setup popup instead
  (`testNothingInThePanelAnswersATouch`).

The clip itself is `LunaMoonPhases.mp4`, and the page and the panel play the same
one — the panel is showing the post's video, not a second video. It is a recut of
NASA SVS's "Moon Phase and Libration, 2026" (`LunaMoonPhasesAttribution.txt`
records the source, the span and the exact `ffmpeg` recipe): the run from a
22%-lit waxing crescent to December's full moon — the year's closest — every
second hour, then played backwards to its own first frame. So it loops with no
seam, and what it shows is **the Moon changing phase**, waxing and waning
forever, over eight seconds.

That is a deliberate replacement for the lunar-eclipse timelapse it opened with.
An eclipse read as a moon vibrating: the frames of totality differ by a slow
shift in the umbra and a tracking wobble, which at video speed is a jitter rather
than an event, and nothing in it changed enough to be worth watching for the four
seconds the lesson now holds. A phase cycle changes visibly every second, which
is what a demonstration of "the video is worth having" needs its video to do.
Both ends of the boomerang are a plainly lit crescent, deliberately: the loop
never bottoms out at a new moon, which on the full-bleed page would be a black
screen. The page shows it `object-fit: cover`, the way a vertical feed does —
the disc is centred in a 16:9 frame, so a portrait crop lands it dead centre.

Both lessons are reviewable without a device pass through onboarding:
`-LunaStage onboarding.safari-lesson` boots any app straight into its browser
with the demonstration about to run, and `-slowOnboardingAnimations` stretches
the holds enough to see each beat.

### The wave takes the clutter away, not the page

The mock extension flip (`OnboardingManageExtensionsSheetView`'s toggle) starts one
climbing front. Three things ride it:

1. **The clutter crumbles.** Every obstruction becomes ~11pt still tiles that
   detach exactly as the front reaches them and fly off (`prepareCleanUp` /
   `animatePreparedShatterPieces`). The front is ONE constant-speed climb over
   the whole page — `measureWaveOrigin` takes its entry edge, `frontArrival`
   is a straight line in a tile's own y — and deliberately not a leg per page
   element: a leg's arrival was constant across the air BETWEEN two elements,
   so the crumble stalled for the height of every gap and then took it in a
   single frame, which is what made the wipe hitch at the popup boundaries.
2. **The content stays still.** It is already visible beneath the clutter, so the
   cleanup never blooms, re-occludes, or otherwise animates it; only obstruction
   tiles move. All tile flights are committed in one Core Animation transaction
   before the sweep begins, avoiding a new render-server commit and stutter when
   the front reaches a large popup.
3. **The browser bar leaves.** `SafariReplicaViewController.setBrowserBarVisible`
   slides the mock address field out with the Manage Extensions sheet — the lesson
   has nothing left to point at in it, and a URL field standing under a finished
   sweep reads as a control the user could tap. The page's bottom reserve is
   released in the same beat, BEFORE the wave's geometry is measured, so the
   content settles first and the front never crosses moving ink. The bar (and the
   reserve) come back with `resetDemonstration` and with any full-screen
   re-presentation (`prepareForPresentation`), because the Action-Button save
   demonstration lights that field; `highlightedLinkRegion` is nil while it is
   away, so a stray replay cannot isolate an empty strip.

### The price tracker demonstrates instead of explaining

The explainer argues for the extension in prose, under clutter, and clears it.
A price tracker can make a better argument — run the extension's actual answer
on an actual product page — so its lesson opens the browser straight on the
mock Amayzon page. Its first pass shows Safari's Manage Extensions bottom sheet
with the **Luna Price Tracker** icon and toggle; later cycle passes skip the
already-taught sheet and play what the extension would do there
(`OnboardingPriceComparisonLesson.swift`, one overlay over the browser holding
three layers in this z-order, which is the whole trick):

1. **The pill is page content.** `OnboardingSellerPillView` reproduces
   `content.js`'s alternative-seller pill point for pixel — bottom-trailing,
   16pt in, `rgba(20,20,26,.85)` capsule, 13pt medium, the pulsing 6pt dot —
   and wears the extension's own two states in the extension's own words
   (`findingSellers` → `Onboarding_Safari_pricePillLooking`, `priceAtSeller` →
   `…_pricePillFoundTemplate`). It arrives on the sheet's exit WITH the black
   spotlight, which zooms over it while it is still searching — the pill used to
   stand alone in the corner for 2.4s first, which read as the demonstration
   having stalled rather than as work. One second after that close, it fills IN PLACE
   with the same eyePhone cheaper at the manufacturer the page already names
   ("Visit the Pearless Devices Store" → `$729.00 at Pearless`, against the
   page's $799.00). The setup popup follows another 0.5s later.
   It is UIKit rather than markup injected into the `WKWebView` because the
   lesson has to measure it: the spotlight closes on its exact frame.
2. **The scrim dims everything but that pill.** `OnboardingSpotlightScrimView`
   is 70% black with ONE round hole, an even-odd mask (bounds rect + circle) —
   only a mask puts a genuinely round edge on the light, and one path animates
   into the next. It opens beyond every screen edge, so its first frame has no
   visible black at all; its 0.3s arrival then brings darkness inward from the
   edges, before closing over
   0.85s to the pill's circumscribed circle plus 12pt. A mask layer has no view
   to inherit UIKit's animation actions from, so every path assignment is
   wrapped in a disabled-actions transaction or Core Animation's implicit fade
   runs against the close.
3. **The shared setup popup stacks on top of both.** There is no card of the
   lesson's own any more — `OnboardingSafariSetupCardView` is deleted outright.
   `AppOnboardingViewController.showSafariSetupPopup()` mounts a
   `SafariSetupScrimView` and then `OnboardingSafariSetupPopupView` on the
   WINDOW, in that order, the instant this overlay reports
   `onDidReachSetupOffer`, so both sit above this lesson's own 70% spotlight —
   both stay visible, deliberately darker where they overlap, rather than one
   replacing the other. The scrim is deliberately its OWN view rather than a
   subview of the popup: it is mounted once and never touched again, so
   nothing in the popup's own layout (its activate-button corona, which
   rebuilds on geometry changes) can ever disturb it — and it is owned by
   the host controller, not by this lesson's own replica, so a cross-sibling
   swap (central Luna's cycle) can't disturb it either. Being window-hosted
   rather than a subview of this overlay is also why the popup is never
   shrunk to fit the room above the closed circle the way the old card was: it
   uses the same generic top-anchored layout every app's popup does.

Every lesson ends in the same place now, so `openSafariSetup`, the skip, and
the return leg with nothing to show for it
(`restoreSharedSafariSetupPopupIfNeeded`, which re-enables the popup's buttons
and re-applies its attention pulse) are shared across all three Safari
lessons. The lesson is re-enterable like the explainer's: `resetDemonstration`
puts the pill back to looking and reopens the hole — the popup itself is
untouched by a reset, since the host's forever-loop is what put the lesson
back in motion underneath it.

### The save lesson performs a real save

`OnboardingSaveDemoController` owns it. There is no mock extension sheet any more:
`OnboardingHostedShareSheetView` is chrome only (scrim, rounded top-corner card at
`cardTop` 66, grabber, the same 0.55s spring in / 0.38s ease out, Reduce-Motion
fades) and carries the real `ShareViewController`, run in-app through
`ShareViewController(hosted:onFinish:)`. Same ingest, same `ShareSurfaceDriver`,
same per-kind presenters, same errors. The hand-drawn
`OnboardingActionExtensionSheetView` — which reproduced the extension reader's
chrome and held a bundled article for a fixed 1.0s — is deleted.

**Which link.** `OnboardingSaveDemoLink.resolve` decides at the moment the user
taps in:

| condition | link | what the surface does |
|---|---|---|
| online, live Save of the Week for this app's kinds | that entry's `urlString` | a genuine fetch, save and presentation |
| online, no live entry | `OnboardingSurfaceConfiguration.practiceURLString` | the extensions' own practice route → the production UI for that link's kind; the temporary row is deleted after the pass |
| offline (`NetworkReachability.isOnline`) | the practice link, flagged | `HostedShareInput.offlineFailure` → `SaveFailureReason.offline`'s real headline, under `wifi.slash`, in the surface's real error state |

The offline terminal takes the failure's **headline** but not its `suggestion`:
"it will retry automatically once you're back online" is true of a save the user
made and false of a rehearsal, whose row is deleted the moment the sheet closes
either way. In its place goes
`ShareExtension_share_hostedOfflineDetail` — the admission that this is the shape
of a save rather than the save. Both the symbol and that second line ride
`ExtensionLoadingViewController.showTerminal(_:symbolName:detail:)`, which every
other failure calls without them.

`practiceURLString` is declared per app (Reader/central luna, Downloader instaTok,
Price Tracker amayzon). It used to be read off the browser's current demo page;
now that every app's Safari lesson opens on `.lunaPage`, deriving it that way would
have handed the Downloader an article to rehearse a media save with.

**Which rehearsal.** Having the right link was only half of it: the practice
short-circuit showed all four apps the same bundled ARTICLE, so the Downloader's
lesson still ended on a page of prose about the video it had just been asked to
fetch. A rehearsal has to rehearse what the app is FOR, so the choice is made
from the link — `ShareSetupPractice.matchesVideoPractice`, since what a link IS
does not change with who opened it — inside `ShareViewController.practicePreview`:

| practice link | rehearsal |
|---|---|
| `luna.app` | `ShareSetupPracticePreviewViewController` — the bundled article |
| `instatok.com`, in an app that handles media | the registered `ShareMediaPresenting` path — `SavedNonTextualViewController`, the production media screen, over the bundled clip |
| `amayzon.web`, in an app that handles products | the registered `ShareProductPresenting` path — a deterministic eyePhone `ProductInfo` drives the real Price Tracker extension editor, seeded with a fabricated price history (below) |

**The media rehearsal is the production media screen.**
`ExtensionMediaPresenter.presentPracticeVideo` mounts
`SavedNonTextualViewController` with a `practiceVideoURL` — the same screen an
action extension shows for a saved video, with its file supplied up front
instead of resolved and transferred. Nothing about a rehearsal touches the
network, the reading list, Photos or the Downloader's library.

Its one asymmetry is WHERE the clip plays. A real save's video is handed to the
host through `onMediaFileReady` and played over the sheet; the rehearsal's plays
INSIDE the preview square (an `AVPlayerLayer`, muted and looping) and the screen
holds the sheet open for `practicePlaybackDuration` (2s) while it does, so the
demonstration never takes a full-screen-looking hop over a screen it has just
built.

**A rehearsed download has no progress to report, so a clock reports it**
(`PracticeDownloadRamp`, LunaShareSurface). The clip ships in the app bundle: it
is on disk before the screen exists, nothing is transferring, and nothing calls
the progress closure a real download drives. So the bar sat at 0 for the whole
indication and the finished screen then replaced it — the one thing the media
lesson exists to show, that a download HAPPENED, was the one thing it never
drew. `beginPracticeDownloadBeat` applies `.downloading` and hands the bar to the
ramp: back to zero, gated on `HostedShareSession.revealDate` (the surface is
built DETACHED well before the sheet opens, so a beat begun at `viewDidLoad`
would be over unseen — nil session, as in a real appex, runs immediately), then
0 → `firstStop` (0.62) → 1 across `duration` (1.5s), and the bundled file
resolves at the top of it. Two steps rather than one long animation because the
bar draws its own ease and a single 1.5s ramp reads as a bar nobody is driving.
The ramp is generation-guarded, so `onReplayBeat` re-runs the whole beat on a
looping pass instead of snapping the bar to 1. A REAL hosted save is untouched —
its progress is the download's own, joined from `MediaPreloadCache` where the
lesson preloaded it.

**The gate that hid it.** That screen asks `MediaDownloadablePlatform.supports`
before building its media half at all — the right question for a real save, and
the wrong one here: `instatok.com` is a fictional host that matches no platform
rule and carries no media extension, so the answer was "not downloadable", the
preview was never built, `beginMediaFlow` returned before applying the file, and
the Downloader's save lesson ended on a bare "Saved to Luna" badge with no video
in it anywhere. `showsInlineMedia` is that question OR `isPracticePreview`: a
practice video is downloadable media by construction, and is the one case the
platform table cannot be asked about.

`ShareSetupPracticeDownloadViewController` — the hand-built rehearsal that keeps
the media screen's grammar (the badge, the square preview with the bar drawn
inside it, the full-width Done) over the same `PracticeDownloadRamp` and a poster
frame — remains the fallback for a media host with no registered media
presenter, and reports its clip through `onMediaFileReady`. Both rehearsals fill
their bar from that one ramp (so the two cannot drift into filling at different
rates) and both answer `onReplayBeat` by re-running their beat on each pass of
the looping demonstration.

The clip lives in the APP bundle only (`ShareSetupPractice.bundledVideoURL`): a
rehearsal is worth 400KB in the app that teaches it and is not worth it in eight
extension bundles that will never run one, so a real appex handed the practice
link falls back to the article preview.

**Timing.** `start(in:)` mounts the surface hidden and lets `viewDidLoad` begin the
work immediately, so the fetch overlaps the conversation animating in front of it;
media additionally preloads through `ShareMediaSideEffects.preloadDownload` into
`MediaPreloadCache`. `present` then waits for the surface's OWN terminal signal
(`HostedShareSession.onReachedTerminal`: a completed request, a presented kind
screen, or visible error text), holds `extensionSheetHoldDuration`, and dismisses.
No timer sits on top of the real work — the surface's 15s attachment watchdog and
the pipeline's 28s ingest budget are the backstops.

**Media.** `HostedShareSession` gates a result behind the reveal plus
`minimumDownloadIndication` (0.3s), so a preloaded file still shows its progress
bar; a ready video is reported via `onMediaFileReady` and played over the sheet by
a `VideoCardContentViewController`, muted and looping, for ~2s — every video
except the REHEARSAL's, which plays in the media screen's own preview square
instead (above) and reports nothing to the host but a wait to hold the sheet
through. The downloaded file
is retained on the session so a demo replay reuses it: each pass calls
`session.replayBeat()`, which the media screen answers by re-running its own
indication off the file it already has. Nothing refetches.

**The product rehearsal's price history.** A brand-new tracker has no history
and an empty graph is the truth for it — except in the one screen whose whole
job is to demonstrate what tracking a price gets you, where it read as an empty
box captioned "no price history yet". `ShareSetupPractice.practicePriceHistory`
is a fabricated quarter — a list price, two forgettable promotions, one real
sale, then today's price, as a staircase, because retail prices are step
functions and a jittering line reads as a stock chart — stated as multiples of
whatever the mock page is priced at, so the shape survives a change to the
product. `ExtensionProductPresenter` seeds it into the new tracker before
saving, matched BY URL (`ShareSetupPractice.matchesProductPractice`) like every
other practice decision, so an Amayzon-shaped real save cannot pick it up by
resembling one. The graph, the alert line and the seller list are the
production ones either way.

**Cleanup and the latch.** The row the surface appends is reported through
`onDidAppendRow`, claimed via `AppOnboardingStore.recordTemporarySave`, and deleted
after every pass along with its `SaveFailureStore` record and the media kind's own
bookkeeping (`ShareMediaSideEffects.deleteSavedContents`).
`markCompletedIfSavedSinceOnboardingStart` EXCLUDES that row: an app must not
complete its own first run on the strength of a rehearsal it played to itself.
`endSaveDemonstration` runs from every route out of onboarding (`deinit` cannot —
it is nonisolated where the controller is main-actor bound).

One evidence rule makes the lesson's own sheet safe: the hosted surface records
none at all (`recordsSetupRunEvidence` is false exactly when `isHosted`), so a
rehearsal never counts as the shortcut having run. A save the user makes through
the real share sheet during the lesson is intentionally KEPT: it is a real save
from a real surface and legitimately answers the first run.

Completing or choosing the lesson's skip/later path both call
`completeSetupFlow`, which passes the OUTCOME through: Safari records
`markSafariSetupHandled(outcome:)`, Messages/save setup
`markSaveSetupHandled(outcome:)`, and a skip is remembered as a skip — the util
card keeps a skipped lesson's button and retires only a completed one
(`claudedocs/util-card.md`). If both are now finished, the explicit completion
marker is also written. The lesson dismisses back to the same production root and
does not replace the carousel.

The Safari demonstration remains storage-free: its mock pages never enter
`readingList.json` or any content directory. The SAVE demonstration is no longer
storage-free in the trivial sense — it runs the real surface — but it is
storage-NEUTRAL: both a live weekly entry and the product fallback append a row
only for the real presenter, mark it temporary, and delete it after each pass
(the article/media practice routes still append nothing). The legacy temporary-demo cleanup
(`BundledLunaArticle.cleanupLegacyTemporarySave`) remains for users updating from an
older build.

### The scripted gestures wear the system's own chrome

Everything the save lesson mimes is somebody else's UI, so it is built out of the
OS's materials rather than hand-mixed colours — deliberately NOT `GlassStyle`,
whose materials are tinted with Luna's own palette.

**The Action Button press.** `saveDelayAfterLastMessage` is the beat between the
link landing and the press: short, because the press is the answer to that link.
The Messages-only ripple is the press cue plus the drawn
`ActionButtonPressWaveView`: a bright core between two dark rims that expands on
the shared `firstWaveDelay`/`firstWaveDuration` timeline. It is deliberately a
single vector overlay rather than a Core Image warp underneath it, so every Luna
host renders the same legible wave over the white iMessage mock.

The mock puts its content as SIBLINGS above its glass rather than inside a glass
content view: a glass content view does not rasterize through `layer.render(in:)`,
and every ending in this flow snapshots the screen it is leaving.

### No lesson survives the hop that covered it

Every ending — either lesson, the finishing handoff, and the settings replay —
takes the mock sources off screen (`hideDemonstrationSources`) UNDER the
app-switcher hop's own frozen last frame, before the window changes hands or the
replay is dismissed. `AppOnboardingCompletionTransition.run` snapshots the window
and reparents the root out of the onboarding controller, which leaves the outgoing
tree owning the screen for a frame; the finishing hop therefore also brings the live
root up first (a raster of that same root is what the hop is already showing, so
nothing moves) and removes the hop afterwards.

## Paste as first-run success path

Paste is no longer an onboarding completion action. It is a permanent utility
action in both card variants. `OnboardingPasteRow` still provides the visible
field and a real `UIPasteControl`; valid URLs run normal ingest and use the util
row-to-card transition, while failure stays in the row. Saving content does not
silently claim that Safari and shortcut setup were completed.

## Setup replay from Settings

Settings → Shortcut & Safari can invoke the same lessons. Those replays use the
same handled/evidence stores and therefore can complete onboarding for the next
launch. Because setup is presented over the live root, completion returns to the
same deck and preserves its current card.

## Debugging and validation

Debug launches accept `-resetOnboarding` (`-resetReaderOnboarding` remains the
Reader alias). The reset clears explicit completion, both handled markers, and
all setup run evidence, so the next host construction is deterministic. It is
the only caller of `AppOnboardingStore.resetCompletion` left: Diagnostics used
to offer an onboarding-only reset and now erases the install outright
(`settings.md`), which reaches these markers by deleting the domain they live
in.

The older lesson inspection arguments remain available for the transient setup
controller: `-onboardingStage`, `-forceActionButtonSetup`,
`-onboardingPreviousShortcutApp`, `-slowOnboardingAnimations`, and
`-onboardingAnimationScale`.

Relevant tests:

- `UtilCardTests`: launch variants, persistent controls, weekly save callback;
- `ReaderOnboardingTests`: per-app markers, central inheritance, the hardware
  rule behind `.actionButtonShortcut` vs `.unavailable`, that entering either
  lesson stores nothing, that every app's Safari lesson (faceted or central)
  raises the shared setup popup and loops underneath it, and that the price
  lesson ends on that popup hittable through — and above — its own stacked
  scrims;
- `OnboardingSaveDemoTests`: link resolution's three branches, the hosted surface
  (practice preview, the real offline failure, one-shot completion, the evidence
  guard), the sheet's chrome-only contract, and the rehearsal's cleanup;
- `ShareSetupPracticeMediaTests`: which link stands for what, the one clip named
  in three places, and that the rehearsal's clip is actually ON SCREEN — a
  player layer, with a player in it, at a real size — where a link with no
  bundled clip still shows none;
- `ExtensionProductPresenterTests`: the merge decision at the presenter's own
  level, plus the rehearsal product arriving with a history the graph can draw
  (and an ordinary new tracker still arriving with none);
- the existing onboarding visual/lesson tests: copy, setup effects, recovery,
  local assets, storage-free demos, Reduce Motion, and launch geometry.
