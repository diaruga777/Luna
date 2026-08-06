# Luna launch and setup lessons

Luna no longer has a standalone onboarding screen or onboarding-only carousel.
Every app launches its production card deck immediately. The permanent util card
at index zero owns first-run copy and the entry points into setup; its full state
and layout contract are documented in `util-card.md`.

This document covers the launch transition, completion model, and the native
Safari and Action Button shortcut lessons that the util card reuses.

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
second beat animates the difference between them. There is no two-line variant;
it was deleted once the diff generalized.

| App | Initial | Final | Anchor that never moves |
|---|---|---|---|
| Reader | “Read.” | “Read more.” | `Read` |
| Luna | “All your Luna apps.” | “One Luna app.” | ` Luna app` |
| Downloader | “Sign in to watch.” | “No Sign in to download.” | `Sign in to ` |
| Price Tracker | “Miss a sale” | “Never miss a sale” | `iss a sale` |

`OnboardingHeadlineTransition` (pure text, `OnboardingHeadlineTransition.swift`)
finds the anchor: the LONGEST continuous run of characters both states carry,
ties going to the run that appears earliest in the final text. Everything before
it and everything after it belongs to one state or the other — whitespace,
punctuation and a letter changing case are ordinary characters here, which is
why Price Tracker's capital “M” leaves with “Never m” arriving in its place.
Copy that shares no run worth standing still for — nothing in common, a single
character, or punctuation only — replaces itself outright (`isFullReplacement`),
each state centred on its own.

`OnboardingIntroHeadlineView` renders that in the two-beat moon-reveal: beat one
brings the initial sentence in whole; beat two blooms the arriving fragments in
and the departing ones out, in the same turn, and never touches the anchor. Two
consequences worth knowing before changing copy or layout:

- **The FINAL sentence is what is centred.** The initial one is typeset wherever
  the anchor's final position puts it, so it lands left of centre when the copy
  grows on the right (Reader) and right of centre when it grows on the left
  (Price Tracker). Nothing translates between beats, because nothing was ever
  anywhere else. Each sentence is one composition with every character but the
  fragment's own in clear ink, so a fragment's position is real typesetting
  rather than a measured offset.
- **A narrow card shrinks the font, not the layout.** Both states have to fit
  side by side (`Metrics.unionWidth`), so the view picks a size from 25pt down to
  a 13pt floor at layout time and rebuilds its fragments if that size changes —
  which it will only do before a beat has begun.

Departures get their own fronts rather than sharing the arrivals'. A period's
ink sits a whole x-height below “more”'s, so one edge descending through the
shared frame would uncover the top of the “m” a third of a second before
reaching the period beside it — long enough to read the wrong sentence. Each
departing fragment's front starts advanced by the drop from the highest arriving
ink (`frontLead(forDeparting:)`), so it goes out as the arrivals come in.

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

- Safari opens on the native `luna.app` explainer page in EVERY app, then rotates
  to that app's own mock page (Downloader `[.lunaPage, .instaTok]`, Price Tracker
  `[.lunaPage, .amayzon]`, Reader `[.lunaPage]`, central all three). It shows the
  extension effect, then guides the user to Safari extension setup. Leaving for real
  Safari stamps `setup.safari.setupTapAt.<app>` + that app's display name, which the
  extension pairs with its OWN first run to confirm setup in the page and invite the
  user back — see `claudedocs/safari-extension.md`'s "in-page setup confirmation".
- The hop into REAL Safari opens `https://www.apple.com`
  (`AppOnboardingViewController.openSafariSetup`). The one requirement is a page
  Safari's own Reader is never offered on: Reader availability rearranges the
  address field — the very menu the lesson just taught — so an article-shaped
  practice page (Wikipedia was one) works against it. A plain homepage is not
  Reader-eligible and carries nothing to attribute for merely being opened.
- Save setup uses the Messages replica and there is exactly ONE of it: the
  Action Button shortcut journey. `OnboardingSaveSetupMode` answers
  `.actionButtonShortcut` or `.unavailable`, and a device that answers
  `.unavailable` is offered no save lesson at all — the util card omits the
  button, and that leg is finished by definition rather than falling back to a
  share-sheet demonstration. Its save is REAL — see below.
- external-open recovery overlays remain available if Safari, Shortcuts, or
  Settings rejects a route.
- Reduce Motion replaces waves and switcher choreography with short fades.

### The Safari explainer's prose fits the screen it lands on

The page's furniture is pinned at both ends: the header at
`OnboardingSafariPageView.minimumTopInset`, the actions block ending exactly on
`chromeReserve` (the mock browser bar's reserve plus 12), the steps and their
heading stacked above it. Iconography, all three step rows and both buttons appear
at every size, unchanged.

The bottom reserve is the bar's, so it goes when the bar does
(`setReservesBrowserChrome`, dropping to `clearedChromeReserve`) — see the wave
below. The PROSE fit is deliberately measured against the FULL `chromeReserve`
either way: reclaiming the strip must not make another chunk of copy appear
mid-lesson, so the reclaimed room becomes air above the steps instead.

The PROSE is the only variable. `OnboardingStrings.Safari.explainerChunks` is a
`ChunkedDefinition` — an ordered list per app, not one string — and the page prints
the largest cumulative prefix that fits between the byline and the steps heading
(`fittedProse`). Each chunk closes its own sub-topic, so a screen that only holds
the first two never shows half an idea; the leftover room becomes air above the
steps, which is the tolerance chunk granularity needs across screen sizes. Chunk
one is the sentence that must survive 375×667 on its own. A container too short
even for that keeps it and truncates, rather than pushing the actions under the
chrome.

Copy differs per app (Reader/central lead with cleanup and one-tap saving,
Downloader with saving the video off its own page, Price Tracker with tracking a
price from it). The 17pt/lineSpacing-5 typography lives once, in
`OnboardingSafariPageView.proseFont` / `proseLineSpacing` / `proseHeight(of:width:)`,
read by the measurement, the label and the tests. `MoonRevealLineView.setText`
names the prose during layout and returns early on unchanged text, which is what
keeps a layout-time text change from scheduling another layout pass.

Per-app selection and the fit at {375×667, 393×852, 430×932, 744×1133, 1024×1366}
are asserted by `testSafariPageGrowsItsProseByWholeChunksAcrossEveryScreen`,
`testSafariPageFitsTheShortestPhoneWithoutTruncatingItsProse` and
`testSafariExplainerCopyIsPerAppAndChunked`.

### The wave takes the clutter away, not the page

The mock extension flip (`OnboardingManageExtensionsSheetView`'s toggle) starts one
climbing front. Three things ride it:

1. **The clutter crumbles.** Every obstruction becomes ~11pt still tiles that
   detach exactly as the front reaches them and fly off (`prepareCleanUp` /
   `animatePreparedShatterPieces`).
2. **The content blooms where it stands.** It is NOT re-occluded and re-revealed:
   the page was legible under the clutter, so blanking it out to hand it back read
   as a glitch. Each element runs a light-only pass (`prepareToBloomAgain` /
   `bloom`) — the intro's own `GlyphPixelBloomView` emitter with no occluder
   behind it, so `MoonRevealContentView` has none at all and `MoonRevealLineView`
   keeps its occluded `reveal` only for the intro. The bloom trails the tile front
   by `contentBloomLag` (0.26s, about a beat and a half of a tile's flight): light
   arriving under grains still in the air is simply crumbled over.
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
| online, no live entry | `OnboardingSurfaceConfiguration.practiceURLString` | the extensions' own practice short-circuit → bundled preview, nothing stored |
| offline (`NetworkReachability.isOnline`) | the practice link, flagged | `HostedShareInput.offlineFailure` → `SaveFailureReason.offline`'s real headline and suggestion in the surface's real error state |

`practiceURLString` is declared per app (Reader/central luna, Downloader instaTok,
Price Tracker amayzon). It used to be read off the browser's current demo page;
now that every app's Safari lesson opens on `.lunaPage`, deriving it that way would
have handed the Downloader an article to rehearse a media save with.

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
a `VideoCardContentViewController`, muted and looping, for ~2s. The downloaded file
is retained on the session so a demo replay reuses it: each pass calls
`session.replayBeat()`, which the media screen answers by re-running its own
indication off the file it already has. Nothing refetches.

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
storage-NEUTRAL: with no live weekly entry the practice short-circuit means nothing
is appended at all, and with one, the row it appends is marked as the temporary save
and deleted after each pass (see above). The legacy temporary-demo cleanup
(`BundledLunaArticle.cleanupLegacyTemporarySave`) remains for users updating from an
older build.

### The scripted gestures wear the system's own chrome

Everything the save lesson mimes is somebody else's UI, so it is built out of the
OS's materials rather than hand-mixed colours — deliberately NOT `GlassStyle`,
whose materials are tinted with Luna's own palette.

**The Action Button press.** `saveDelayAfterLastMessage` is the beat between the
link landing and the press: short, because the press is the answer to that link.
The press itself is the press cue plus `LiquidScreenWaveAnimator.playRipple`, and
because a ripple-only press renders no blackout and no crossfade, the warp is the
only thing reporting it — which on the white iMessage mock is nearly nothing, since
the warp's lighting term brightens toward white. So the front is also DRAWN:
`ActionButtonPressWaveView` strokes the same expanding circle (a bright core
between two dark rims, so it reads on white and on black), on the warp's own
`firstWaveDelay`/`firstWaveDuration`, in the window beside the cue.

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
all setup run evidence, so the next host construction is deterministic.

The older lesson inspection arguments remain available for the transient setup
controller: `-onboardingStage`, `-forceActionButtonSetup`,
`-onboardingPreviousShortcutApp`, `-slowOnboardingAnimations`, and
`-onboardingAnimationScale`.

Relevant tests:

- `UtilCardTests`: launch variants, persistent controls, weekly save callback;
- `ReaderOnboardingTests`: per-app markers, central inheritance, the Safari page's
  fitting/prefix contract, the hardware rule behind `.actionButtonShortcut` vs
  `.unavailable`, and that entering either lesson stores nothing;
- `OnboardingSaveDemoTests`: link resolution's three branches, the hosted surface
  (practice preview, the real offline failure, one-shot completion, the evidence
  guard), the sheet's chrome-only contract, and the rehearsal's cleanup;
- the existing onboarding visual/lesson tests: copy, setup effects, recovery,
  local assets, storage-free demos, Reduce Motion, and launch geometry.
