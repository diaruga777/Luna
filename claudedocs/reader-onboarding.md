# Luna launch and onboarding

The central Luna app and all three faceted apps use one launch/onboarding
engine. Each composition root injects an immutable
`AppOnboardingCompletion`; surface copy and offline demo pages come from
`OnboardingSurfaceConfiguration`.

## Every app launch

`ReaderLaunchScreen.storyboard` is a static rendering of a blank black
`CardSurfaceView`, its real glass rim, and `EclipseCorona` over the fixed
starfield. The black card uses the production root deck's exact 24-point side
insets and 9:16 resting size; the much wider corona is deliberately cropped at
the display edges instead of shrinking the card to keep every ray visible.
There is no app chrome or content.

This happens after onboarding is complete too. The transition asks the
destination carousel for its real resting frame through
`AppLaunchTransitionTarget`, draws the live splash card at that frame, and
crossfades the single splash layer into the fully laid-out root in 0.18 seconds.
There is no launch hold, card resize, or staged eclipse egress.

The static images are generated from production views. To regenerate them after
changing the corona, rim, tint, or star table, run
`ReaderLaunchArtRecorderTests.testRecordReaderLaunchArtworkWhenRequested` with
`TEST_RUNNER_READER_LAUNCH_ART_DIR=<output directory>`, then replace the PNGs in
`ReaderLaunchStarfield.imageset` and `ReaderLaunchCoronaCard.imageset`.

## Per-app configuration

| App | Intro lines | Demonstration | Save benefit |
|---|---|---|---|
| Reader | “You wish you read more.” / “Let’s make that happen.” | bundled Luna Wikipedia page | “Read offline later” |
| Downloader | “App signup required? So annoying.” / “Watch and share instantly instead.” | bundled InstaTok page and eclipse video | “Watch or share” |
| Price Tracker | “Overpaid? Missed a sale?” / “Never miss out again.” | bundled amayzon eyePhone page | “Never miss a sale” |
| Luna | “All your Luna saves.” / “In a single app.” | continually rotates through all three pages | “Read, watch, track, anything” |

The InstaTok page is a deliberately fictional full-bleed video site whose
signup modal blocks a bundled NASA SVS lunar-eclipse clip. The source, SHA-256,
and NASA media guidance URL live in `LunaEclipseAttribution.txt`. The amayzon
page and final product image use a deliberately fictional, logo-free,
asymmetric “eyePhone”.

## Incomplete first run

`AppOnboardingStore` persists one standard-defaults completion key per app;
Reader retains its shipped `reader.onboarding.completed.v1` key. These markers
are not in the App Group: setup evidence and saves are shared, while every app
owns its onboarding completion independently.

The root uses the production `CardCarouselViewController`:

1. The first black card reveals both surface-specific lines. A black circular
   occluder translates down each line; exposed text passes through a narrow
   white bloom before resolving. The text starts one third of the way down the
   card. “Show me how” appears only after both lines.
2. The button pages through the production `CardEclipseTransition`. The next
   card expands to the display and becomes `SafariReplicaViewController`.
3. The noninteractive `WKWebView` and native UIKit Safari facsimile load only
   bundled files with a nonpersistent data store and JavaScript disabled.
   Central Luna changes the local page and displayed host every 3.4 seconds.
4. An Action Button cue plays beside the physical button. A moving
   `CIBumpDistortionLinear` strip deforms every pixel of a whole-window snapshot
   before removing itself after the pixels settle.
5. A window-filling near-black overlay aligns its content to the same one-third
   vertical anchor. It offers Safari setup, then the same `BundledShortcut`
   installer and `SystemSettingsLink.openActionButton()` paths used elsewhere.
   Existing Safari and Action Button PiP guides play during external hops.
6. After Settings return, a real App Intent invocation completes the flow
   through `LunaSetupStatusStore.didChange`; “Set up later” reaches the same
   completion path.
7. Completion installs the surface's real save and eclipses into its normal
   deck: Wikipedia article for Reader and central Luna, local video for
   Downloader, and a real price-tracker payload for Price Tracker.

The demonstration save is temporary. Its exact UUID is recorded only when
onboarding created a new item. The owning app deletes that exact save and its
local media/image on the first background callback, then clears the UUID. A
pre-existing matching user save is never claimed or removed. Launch also sweeps
a marker left by a process terminated during a background transition.

If iOS terminates an app while Safari or Settings is foreground, the next
launch starts incomplete onboarding from its first card; completion is not
inferred from merely opening a destination.

## Validation

Debug launches accept `-resetOnboarding` (`-resetReaderOnboarding` remains a
Reader alias). `-onboardingStage prompt|setup|waiting` moves through the real
card eclipse and expansion but begins at a deterministic overlay stage;
`-readerOnboardingStage` remains an alias. Add `-slowOnboardingAnimations` for
a 6× inspection timeline, or `-onboardingAnimationScale <1...12>` for an
explicit factor. The clock slows Core Animation, timers, and the display-link
liquid wave together.

`ReaderOnboardingTests` covers independent per-app completion, exact surface
copy/page mapping, temporary-save ownership, idempotent offline article
installation, launch geometry, local-only HTML, bundled MP4 size, and
attribution. The launch-art recorder remains skipped in ordinary test runs.
