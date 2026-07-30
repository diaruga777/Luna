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
egress. The target is told the moment the fade BEGINS
(`appLaunchTransitionWillReveal`) — the splash and the content beneath are
pixel-identical, so onboarding starts its first lunar reveal right then
instead of waiting out the crossfade; `appLaunchTransitionDidFinish` still
fires at completion. On an incomplete first run only, a separate `EclipseCoronaView`
reconstructs the identical static peak behind the intro card, so the corona
remains stationary and fully visible after the launch layer is discarded.
Completed roots do not retain it.

The storyboard pins one standalone, opaque `LunaLaunchComposite` PNG to the
full screen instead of asking the launch-snapshot process to resolve asset
catalog layers. Its 402×874 reference canvas contains the real card frame and
starfield, and does not rely on a negatively positioned image view, which iOS
can omit from a launch snapshot. The composite and its diagnostic source layers
are generated from production views. The renderer intentionally contains no
colored solar prominences. To regenerate the assets after changing the corona,
rim, tint, or star table, run
`ReaderLaunchArtRecorderTests.testRecordReaderLaunchArtworkWhenRequested` with
`TEST_RUNNER_READER_LAUNCH_ART_DIR=<output directory>`, then replace
`Luna/LunaLaunchComposite{,@2x,@3x}.png` and the diagnostic PNGs in
`ReaderLaunchStarfield.imageset` and `ReaderLaunchCoronaCard.imageset`.

## Per-app configuration

| App | Intro lines | Supporting lines | Demonstration | Save benefit |
|---|---|---|---|---|
| Reader | “You want to read more.” / “Let’s make that happen.” | “Save onscreen links with one click.” / “Unlock or read offline later.” | native `luna.app` article sequence | “Read offline later” |
| Downloader | “App signup required? So annoying.” / “Watch and share instantly instead.” | “Download any video link in one click,” / “no signup required.” | bundled InstaTok page and eclipse video | “Watch or share” |
| Price Tracker | “Overpaid? Missed a sale?” / “Never miss out again.” | “Track sales for any link” / “in one click.” | bundled amayzon eyePhone page | “Never miss a sale” |
| Luna | “All your Luna saves.” / “In a single app.” | “Save any link on your screen” / “with one click.” | continually rotates through all three pages | “Read, watch, track, anything” |

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

1. The instant the launch splash begins its fade, with no settling delay, a
   completely borderless black circle
   moves slowly down across the surface-specific first line. After a brief
   0.32-second reading beat, the same reveal plays across the second line. The
   circle is fully opaque, while
   the ordinary glyph layer is also geometrically excluded from its interior,
   preventing subpixel text from bleeding through. Four narrow illumination
   bands intersect a native-scale raster of the actual antialiased glyph
   pixels—not a label or word-sized region. That transient emitter is rendered
   into a padded light pass with five-scale additive near/middle/wide halos:
   brightness falls steeply with distance from the circle edge, the clipped
   white core briefly overwhelms legibility, and each pixel's bloom illuminates
   its neighbors before resolving to ordinary text. The copy
   starts one third of the way down the card. After the second line finishes,
   the surface-specific two-line supporting copy fades in halfway between the
   headline and the “Show me how” button, which gives it equal breathing room
   above and below. The button appears with it, using a restrained 24% wash of
   the current app surface tint in its glass background. A new UIKit corona
   independently reconstructs the splash's static peak behind this initial card
   for the entire intro; neither the launch raster nor its overlay hierarchy is
   retained.
2. “Show me how” does not page or invoke `CardEclipseTransition`. The centered
   intro corona is removed when the button advances successfully, then the card
   grows directly to the display edges while its contents crossfade into
   `SafariReplicaViewController`. Once it is full-screen, the hidden carousel
   prepares the saved-content slot without animating between cards. Everything
   the demonstration needs — the setup guide players (AVFoundation, kept off
   the launch frame), the temporary save, the mounted production root, the
   saved-card wave raster, and both source replicas (hidden, so Safari's
   WKWebView loads its bundled page early) — is preloaded one run-loop turn
   after the first appearance commits, while the static launch splash still
   covers the screen, so the stall is invisible and the button press pays only
   for the expansion animation itself. A failed temporary-save install stays
   silent at preload; the press retries it and surfaces the failure alert.
3. The Reader's Safari content is a native, fictional `luna.app` article so its
   sequence begins after the card finishes expanding rather than during hidden
   preload. “Save anything in Safari” and its offline body copy use the same
   glyph-pixel eclipse reveal as the intro. An obnoxious radial-striped banner
   is completely absent until it slides in from the right, then its rays rotate
   continuously. A huge dark “Subscribe!” popup springs over most of the page
   before revealing “...or not / Say good bye to popups and just read”, and
   “In just one click.” receives the final eclipse reveal.
   Only then does the existing Action Button save effect begin. Other demo
   surfaces remain bundled, noninteractive `WKWebView` pages with a
   nonpersistent data store and JavaScript disabled; central Luna rotates its
   local pages every 3.4 seconds.
   The second source is a native UIKit iMessage facsimile headed **Johnny
   Appleseed**. Three readable, content-hugging bubbles spring in one at a time:
   “You can save any link on your screen, too”, “Really? Like this?”, and the
   exact URL currently shown by Safari. A 1.6-second reading beat separates
   arrivals. The existing Action Button save effect follows the final bubble.
4. A solid-black, tall rounded deformation stretches continuously out of the
   physical Action Button screen edge and smoothly retracts, matching the
   system's on-screen press silhouette. Its system-scale footprint is 7 points
   deep by 120 points tall and is centered on the Action Button's physical
   position. The screen holds still for a 0.2-second beat while the bulge
   forms; a custom Core Image warp then sets out just as the fully grown bulge
   starts to recede. This first, thick wave is displacement-only: it passes
   through the source pixels without replacing them, and finishes before the
   next phase starts.
5. A second wave then creeps in from the display edges, closing in on the
   rounded boundary of the highlighted Safari URL bar or iMessage link bubble.
   Every pixel behind its inward-travelling front turns black while the
   highlighted link itself is preserved, until only that link is visible on
   black. Both waves stay concentrated at their moving wavefronts instead of
   bending every pixel inside one growing `CIBumpDistortion` radius. There is
   no third wave: the isolated link rests on black for half a second, then the
   whole frame simply crossfades, uniformly across the screen, into the
   saved-card snapshot.
6. Before Safari opens, onboarding installs the target's temporary save and
   lazily mounts the complete production root returned by that app's
   `AppOnboardingCompletion`. The final crossfade lands on that root
   carousel's exact centered card state; the live hierarchy is committed under
   the final composited frame.
   Reader, Downloader, Price Tracker, and central Luna therefore show their
   ordinary saved-card UI, chrome, scrubber, controls, and placement—not an
   onboarding remake or a Safari view clipped smaller.
7. Setup deliberately splits the demonstrations. Safari saves first, its card
   remains unobscured for 1.35 seconds, and only the Safari-setup overlay
   appears. Returning from Safari dismisses that overlay, grows the Messages
   replica from the saved card, plays its three-bubble sequence, and runs the
   second Action Button save. After another 1.35-second card hold, the shortcut
   and Action Button setup overlay appears. Setup overlays do not run a second
   source behind themselves. At the start of each press, the source URL gains a
   bright app-tint highlight; it survives the blackout wave until the saved
   view replaces it. The setup actions retain the same `BundledShortcut`
   installer and `SystemSettingsLink.openActionButton()` paths and PiP guides.
   If Safari, Shortcuts, or Settings rejects the open request, the overlay stays
   in place and offers recovery. While present it is an accessibility modal and
   hides the mounted production hierarchy from assistive technologies.
8. After Settings return, a real App Intent invocation completes the flow
   through `LunaSetupStatusStore.didChange`; “Set up later” reaches the same
   completion path.
9. Completion stops any active presentation and, unless it is already there, shrinks to the
   card once more. The real save and production root are already present, so it
   marks onboarding complete and crossfades the stationary production card into
   the fresh completed root—no eclipse or second geometry change. The payload
   is the fictional `luna.app` article for Reader and central Luna, local video for
   Downloader, and a real price tracker for Price Tracker.

With Reduce Motion enabled, the full-screen Core Image wave is replaced by a
short source-to-saved-card crossfade. The two saves reuse one Core Image context,
avoiding device-context and shader-cache setup between Safari and Messages.

The demonstration save is temporary. Its exact UUID is recorded only when
onboarding created a new item. The owning app deletes that exact save and its
local media/image on the first background callback after onboarding completes,
then clears the UUID. It deliberately survives the incomplete onboarding
background hops to Safari, Shortcuts, and Settings because the production root
needs it for each replay. A pre-existing matching user save is never claimed or
removed. Launch also sweeps a marker left by an abandoned or terminated run.

If iOS terminates an app while Safari or Settings is foreground, the next
launch starts incomplete onboarding from its first card; completion is not
inferred from merely opening a destination.

## Validation

Debug launches accept `-resetOnboarding` (`-resetReaderOnboarding` remains a
Reader alias). `-onboardingStage prompt|setup|waiting` moves through the real
direct card expansion and first shrink but begins at a deterministic overlay stage;
`-onboardingStage messages` holds on the unobscured Messages replica for visual
inspection.
`-readerOnboardingStage` remains an alias. Add `-slowOnboardingAnimations` for
a 6× inspection timeline, or `-onboardingAnimationScale <1...12>` for an
explicit factor. The clock slows Core Animation, timers, and the display-link
liquid wave together.

`ReaderOnboardingTests` covers independent per-app completion, exact surface
copy/page mapping, temporary-save ownership, idempotent offline article
installation, launch geometry, active-wave cancellation, external-open fallback
actions, local-only HTML, bundled MP4 size, and attribution. The launch-art
recorder remains skipped in ordinary test runs.
