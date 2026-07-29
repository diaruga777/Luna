# Luna launch and onboarding

The central Luna app and all three faceted apps use one launch/onboarding
engine. Each composition root injects an immutable
`AppOnboardingCompletion`; surface copy and offline demo pages come from
`OnboardingSurfaceConfiguration`.

## Every app launch

`LunaLaunchScreen.storyboard` is a static rendering of a blank black
`CardSurfaceView`, its real glass rim, and `EclipseCorona` over the fixed
starfield. The black card uses the production root deck's exact 24-point side
insets and 9:16 resting size; the much wider corona is deliberately cropped at
the display edges instead of shrinking the card to keep every ray visible.
There is no app chrome or content.

This happens after onboarding is complete too. The transition asks the
destination carousel for its real resting frame through
`AppLaunchTransitionTarget`, draws the live splash card at that frame, and
keeps it visible for 0.10 seconds before crossfading the single splash layer
into the fully laid-out root over 0.20 seconds. The first live frame cannot skip
the eclipse even on a warm launch. There is no card resize or staged eclipse
egress.

The storyboard pins one standalone, opaque `LunaLaunchComposite` PNG to the
full screen instead of asking the launch-snapshot process to resolve asset
catalog layers. Its 402×874 reference canvas contains the real card frame and
starfield, and does not rely on a negatively positioned image view, which iOS
can omit from a launch snapshot. The composite and its diagnostic source layers
are generated from production views. To regenerate them after changing the
corona, rim, tint, or star table, run
`ReaderLaunchArtRecorderTests.testRecordReaderLaunchArtworkWhenRequested` with
`TEST_RUNNER_READER_LAUNCH_ART_DIR=<output directory>`, then replace
`Luna/LunaLaunchComposite{,@2x,@3x}.png` and the diagnostic PNGs in
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

1. The first black card shows its surface-specific first line immediately. It
   holds for 1.45 seconds, then a completely borderless black circle moves
   slowly down across only the second line. The circle is fully opaque, while
   the ordinary glyph layer is also geometrically excluded from its interior,
   preventing subpixel text from bleeding through. Four narrow illumination
   bands intersect a native-scale raster of the actual antialiased glyph
   pixels—not a label or word-sized region. That transient emitter is rendered
   into a padded light pass with five-scale additive near/middle/wide halos:
   brightness falls steeply with distance from the circle edge, the clipped
   white core briefly overwhelms legibility, and each pixel's bloom illuminates
   its neighbors before resolving to ordinary text. The copy
   starts one third of the way down the card. “Show me how” appears only after
   the second line finishes, with a restrained 24% wash of the current app
   surface tint in its glass background.
2. “Show me how” does not page or invoke `CardEclipseTransition`. The centered
   intro card grows directly to the display edges while its contents crossfade
   into `SafariReplicaViewController`. Once it is full-screen, the hidden
   carousel prepares the saved-content slot without animating between cards.
3. The noninteractive `WKWebView` and native UIKit Safari facsimile load only
   bundled files with a nonpersistent data store and JavaScript disabled.
   Central Luna changes the local page and displayed host every 3.4 seconds.
4. A compact solid-black bezel deformation plays beside the physical Action
   Button. In the same run-loop turn, a custom Core Image warp sends a narrow,
   two-lobed annular wavefront from that point across a whole-window snapshot;
   it settles in 0.74 seconds. This keeps the wavefront slim and pronounced
   instead of bending every pixel inside one growing `CIBumpDistortion` radius.
5. Only after the last distorted pixels settle does Safari shrink into the
   exact centered card frame. On Reader, Safari simultaneously dissolves away
   to reveal a real `ReaderHostFactory`/`RabbitHoleReaderViewController`, backed
   by the bundled article and explicitly opened in Scroll mode. The
   target-specific reader is injected through `AppOnboardingCompletion`, so the
   shared onboarding controller does not force Reader dependencies into the
   Downloader or Price Tracker targets. The saved state is therefore real
   Reader content, not the Safari facsimile clipped smaller.
6. The window-filling near-black setup overlay appears after that first shrink
   and aligns its content to the same one-third vertical anchor. Behind it, the
   saved card resets to full-screen Safari, pauses briefly, and replays the
   complete Action Button press + wave + saved-card transformation. The loop
   pauses during external hops and resumes behind each updated instruction
   stage. The overlay offers Safari setup, then the same `BundledShortcut`
   installer and `SystemSettingsLink.openActionButton()` paths used elsewhere;
   existing Safari and Action Button PiP guides play during those hops.
7. After Settings return, a real App Intent invocation completes the flow
   through `LunaSetupStatusStore.didChange`; “Set up later” reaches the same
   completion path.
8. Completion stops the loop and, unless it is already there, shrinks to the
   card once more. It installs the surface's real save, then crossfades the
   stationary onboarding card directly into the completed root controller's
   centered card—no eclipse or second geometry change. The payload is a
   Wikipedia article for Reader and central Luna, local video for Downloader,
   and a real price tracker for Price Tracker.

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
direct card expansion and first shrink but begins at a deterministic overlay stage;
`-readerOnboardingStage` remains an alias. Add `-slowOnboardingAnimations` for
a 6× inspection timeline, or `-onboardingAnimationScale <1...12>` for an
explicit factor. The clock slows Core Animation, timers, and the display-link
liquid wave together.

`ReaderOnboardingTests` covers independent per-app completion, exact surface
copy/page mapping, temporary-save ownership, idempotent offline article
installation, launch geometry, local-only HTML, bundled MP4 size, and
attribution. The launch-art recorder remains skipped in ordinary test runs.
