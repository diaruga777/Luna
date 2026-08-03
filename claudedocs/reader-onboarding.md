# Luna launch and setup lessons

Luna no longer has a standalone onboarding screen or onboarding-only carousel.
Every app launches its production card deck immediately. The permanent util card
at index zero owns first-run copy and the entry points into setup; its full state
and layout contract are documented in `util-card.md`.

This document covers the launch transition, completion model, and the native
Safari/Shortcut/share lessons that the util card reuses.

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

The launch composite is generated from production views. To re-record it after
intentional corona/rim/star changes, run
`ReaderLaunchArtRecorderTests.testRecordReaderLaunchArtworkWhenRequested` with
`TEST_RUNNER_READER_LAUNCH_ART_DIR=<output directory>`, then replace the
`LunaLaunchComposite` and diagnostic assets.

## Surface headlines

| App | Util-card headline |
|---|---|
| Reader | “Read.” growing into “Read more.” |
| Downloader | “App signup required? So annoying.” / “Watch and share instantly instead.” |
| Price Tracker | “Overpaid? Missed a sale?” / “Never miss out again.” |
| Luna | “All your Luna saves.” / “In a single app.” |

`OnboardingIntroHeadlineView` retains the existing two-beat moon-reveal
animation. Reader uses `growingLine`; the others use two lines. The util card
starts that animation from `cardDidBecomeCentered`, so it does not spend the
animation while mounted only as a side peek.

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
  extension effect, then guides the user to Safari extension setup.
- The hop into REAL Safari opens `https://www.apple.com`
  (`AppOnboardingViewController.openSafariSetup`). The one requirement is a page
  Safari's own Reader is never offered on: Reader availability rearranges the
  address field — the very menu the lesson just taught — so an article-shaped
  practice page (Wikipedia was one) works against it. A plain homepage is not
  Reader-eligible and carries nothing to attribute for merely being opened.
- Save setup uses the Messages replica and selects the Action Button shortcut
  journey or share/action-extension journey from
  `OnboardingSurfaceConfiguration.saveSetupMode`. Its save is REAL — see below.
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

Two evidence rules make the lesson's own share sheet work. The real extension now
records `recordShareActionRun` for ANY handled URL, not only the bundled practice
link — the lesson hands the real sheet a real weekly pick, and that save is the
evidence `resolvePracticeShareSheetReturn` is looking for. The hosted surface
records none at all (`recordsSetupRunEvidence` is false exactly when `isHosted`). A
save the user makes through the real share sheet during the lesson is intentionally
KEPT: it is a real save from a real surface and legitimately answers the first run.

Completing or choosing the lesson's skip/later path both call
`completeSetupFlow`. Safari records `markSafariSetupHandled`; Messages/save setup
records `markSaveSetupHandled`. If both are now finished, the explicit completion
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

## Paste as first-run success path

Paste is no longer an onboarding completion action. It is a permanent utility
action in both card variants. `OnboardingPasteRow` still provides the visible
field and a real `UIPasteControl`; valid URLs run normal ingest and use the util
row-to-card transition, while failure stays in the row. Saving content does not
silently claim that Safari and Shortcut/share setup were completed.

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
  fitting/prefix contract, and that entering either lesson stores nothing;
- `OnboardingSaveDemoTests`: link resolution's three branches, the hosted surface
  (practice preview, the real offline failure, one-shot completion, the evidence
  guard), the sheet's chrome-only contract, and the rehearsal's cleanup;
- the existing onboarding visual/lesson tests: copy, setup effects, recovery,
  local assets, storage-free demos, Reduce Motion, and launch geometry.
