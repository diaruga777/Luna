# Luna Reader onboarding

Luna Reader has a launch and first-run sequence that is intentionally absent
from Downloader and Price Tracker. `KindWiring+Reader` is the only composition
root that installs it.

## Every Reader launch

The Reader launch storyboard is a static rendering of the production eclipse at
totality: a blank black `CardSurfaceView`, its real glass rim and complete
`EclipseCorona`, centered over the fixed Reader-tinted starfield. There is no app
chrome or content at this point. `ReaderLaunchTransition` immediately replaces
the storyboard with the same live hierarchy, then plays only the egress:
the corona and opaque moon resolve into the real resting center-card frame while
the card contents, side peeks, scrubber, and other chrome appear.

This runs on completed launches too. The transition asks the destination
carousel for its real resting frame through `ReaderLaunchTransitionTarget`;
launch code must not duplicate the carousel's safe-area or layout math.
`ReaderLaunchGeometry` fits the corona group on both axes so its 42%-of-body
reach remains visible in iPhone portrait and iPad landscape.

The two launch-screen images are generated from the production views rather
than maintained by eye. To regenerate them after changing the corona, rim, tint,
or star table, run
`ReaderLaunchArtRecorderTests.testRecordReaderLaunchArtworkWhenRequested` with
`TEST_RUNNER_READER_LAUNCH_ART_DIR=<output directory>`, then replace the PNGs in
`ReaderLaunchStarfield.imageset` and `ReaderLaunchCoronaCard.imageset`.

## Incomplete first run

`ReaderOnboardingStore` persists
`reader.onboarding.completed.v1` in Reader's standard defaults. It deliberately
does not use the shared App Group: the setup evidence and reading list are
shared, but Reader owns this experience. Until the marker is written, the
Reader root is `ReaderOnboardingViewController`; the other apps keep their
ordinary roots.

The onboarding root uses the production `CardCarouselViewController`:

1. The first black card reveals “You wish you read more.” and, after a short
   pause, “Let’s make that happen.” A black circular occluder translates down
   each line. The newly exposed text passes through a narrow white bloom before
   resolving to the final glyphs. “Show me how” appears at the card bottom only
   after both lines complete.
2. “Show me how” pages to the second card through the production
   `CardEclipseTransition`. After egress, that card expands to the display and
   becomes `SafariReplicaViewController`.
3. The Safari replica is a noninteractive `WKWebView` plus iOS 26 compact-bottom
   Safari chrome. It loads `LunaWikipedia.html` from the app bundle with a
   nonpersistent data store and JavaScript disabled; no network request is
   required. The page and the final extracted article both carry the Wikipedia
   revision and CC BY-SA attribution.
4. An Action Button press cue plays beside the physical button. A moving
   `CIBumpDistortionLinear` strip then deforms a snapshot of the whole window,
   including the browser and system chrome, and removes itself after the pixels
   settle.
5. The dark setup overlay first offers Safari setup. It reuses
   `SetupGuideVideo(.safariExtension)` and the same Safari hop as the left tray.
   On return it offers the same `BundledShortcut` installer and
   `SystemSettingsLink.openActionButton()` path already used in the app, with
   the existing Action Button PiP guide.
6. After the Settings return, the overlay says “Press the action button to
   finish” and offers “Set up later.” A real App Intent invocation completes the
   flow through `LunaSetupStatusStore.didChange`; “Set up later” reaches the same
   completion path.
7. Completion installs `ReaderBundledLunaArticle` through the ordinary
   `ReadingListStore`, writes the onboarding marker, and eclipses into a normal
   `ArticleCardsViewController`. Both the extracted Reader content and the
   Safari-shaped HTML are bundled for offline use.

If iOS terminates Reader while Safari or Settings is foreground, the next
launch starts the incomplete onboarding from its first card, as required; no
completion marker is inferred from merely opening a setup destination.

## Validation

Debug launches accept `-resetReaderOnboarding`. For deterministic visual checks,
`-readerOnboardingStage prompt|setup|waiting` moves through the real card eclipse
and expansion but begins the Safari replica at that overlay stage. These flags
do not exist in Release behavior.

`ReaderOnboardingTests` covers per-app completion persistence, idempotent real
store installation of the offline article, launch geometry on supported screen
shapes, and the local-only HTML contract. The launch-art recorder is skipped in
ordinary test runs.
