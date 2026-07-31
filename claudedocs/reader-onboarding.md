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
egress. A target whose live hierarchy is pixel-identical to the splash
(incomplete onboarding, via `prefersInstantLaunchReveal`) collapses that to
one visible splash frame (0.02s) and a 0.05s fade — the crossfade reveals
nothing there and only masks sub-pixel differences. The target is told the
moment the fade BEGINS (`appLaunchTransitionWillReveal`) — onboarding starts
its first lunar reveal from that instant (after a brief 0.15s settling beat);
`appLaunchTransitionDidFinish` still fires at completion. On an incomplete first run only, a separate `EclipseCoronaView`
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

| App | Intro lines | Demonstration | Save benefit |
|---|---|---|---|
| Reader | “You want to read more.” / “Let’s make that happen.” | native `luna.app` article sequence | “Read offline later” |
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

1. A brief 0.15-second settling beat after the launch splash begins its
   near-instant fade, a
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
   the “Show me how” button appears, using a restrained 24% wash of the current
   app surface tint in its glass background. The intro card remains black and
   contains no icon cluster or supporting copy. A new UIKit corona
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
   WKWebView loads its bundled page early) — is preloaded in STAGES, one per
   run-loop turn, starting when the first line's reveal completes
   (`onFirstLineRevealed`). Staging is load-bearing: heavy work sharing a
   run-loop turn with a just-added CAAnimation delays that animation's first
   commit, and the render server then starts it visibly partway through its
   duration. The button press pays only for the expansion animation itself. A
   failed temporary-save install stops the chain silently; the press retries
   it and surfaces the failure alert.
3. The Reader's Safari content is a native, fictional `luna.app` article so its
   sequence begins after the card finishes expanding rather than during hidden
   preload. The page loads ALREADY BURIED: four garish ads, the newsletter
   popup, and the subscription wall are all in place from the first frame (no
   entrance animations), over a short article — headline, byline, NASA
   eclipse banner, and a seven-line body — sized so the setup card shares the
   same screen and no scroll is ever needed. That body is a **short bulleted
   list of what the reader actually does** (clutter and paywall removal, offline
   copies, the speed reader, read-aloud with the screen off, inline links,
   Kindle and export) rather than marketing prose — the article is the
   demonstration's only chance to say what the app is for. The copy lives once
   in `OnboardingLunaArticleCopy`, and all three surfaces showing this article
   read from there: this page, the mock action-extension sheet the Messages
   shortcut run slides up, and the temporary save the deck shows afterwards.
   **One short line per bullet is a layout constraint, not a style choice**: the
   one-screen budget leaves the body about seven lines, so a bullet long enough
   to wrap costs two of them and pushes the setup card under the browser chrome
   (`testLunaArticleLoadsBuriedWithTheCardSharingTheScreen` is the guard).
   The mock page alone uses a dark
   neutral grey that keeps white copy legible. The demonstration then plays a
   mock extension-enable pass through Safari's own UI
   (`OnboardingSafariSetupMocks.swift`), deliberately reduced to its ONE
   load-bearing beat: no page menu, no scroll down its list, no tap — the
   Manage Extensions bottom sheet slides straight up over the buried page with
   the app's real icon and name beside a mock switch, and the switch flips on.
   That flip IS the cleanup wipe's cue (step 7): the wipe sets out with it and
   plays while the sheet slides back down, rather than waiting the sheet out.
   Other demo
   surfaces remain bundled, noninteractive `WKWebView` pages with a
   nonpersistent data store and JavaScript disabled; central Luna rotates its
   local pages every 3.4 seconds.
   The second source is a native UIKit iMessage facsimile headed **Johnny
   Appleseed**, styled like the real app: `#007AFF` outgoing / `#E9E9EB`
   incoming bubbles with the classic outward tail curl on the last bubble of
   each same-sender group (2-point grouped spacing, 8 between groups), and each
   arrival pops out of its tail corner while the whole bottom-anchored thread
   springs up, the way iMessage lands a new message. Message text is 19pt
   (demonstration-size, not the real app's 17), the composer sits 30 points
   above the home area to leave a strip for the later "or skip" button, and
   the compose field is empty. Three staged bubbles
   arrive one at a time — “You can press the Action Button and Luna saves any
   link on screen”, “Woah! Like this?”, and the exact URL currently shown by
   Safari (underlined link-blue, `https://luna.app/about` for the article
   page). A 1.6-second reading beat separates arrivals. The Action Button
   press effect follows the final bubble — but see step 5a: in Messages the
   save resolves as a mock shortcut run, not the blackout crossfade.
4. A solid-black, tall rounded deformation stretches continuously out of the
   physical Action Button screen edge and smoothly retracts, matching the
   system's on-screen press silhouette. Its system-scale footprint is 7 points
   deep by 120 points tall and is centered on the Action Button's physical
   position. The screen holds still for a 0.2-second beat while the bulge
   forms; a custom Core Image warp then sets out just as the fully grown bulge
   starts to recede. This first, thick wave is displacement-only: it passes
   through the source pixels without replacing them, and finishes before the
   next phase starts.
5. In Safari (`OnboardingSaveEffectStyle.isolateAndCrossfade`) a second wave
   then creeps in from the display edges, closing in on the
   rounded boundary of the highlighted Safari URL bar.
   Every pixel behind its inward-travelling front turns black while the
   highlighted link itself is preserved, until only that link is visible on
   black. Both waves stay concentrated at their moving wavefronts instead of
   bending every pixel inside one growing `CIBumpDistortion` radius. There is
   no third wave: the isolated link rests on black for half a second, then the
   whole frame simply crossfades, uniformly across the screen, into the
   saved-card snapshot.

   5a. Messages instead uses `.rippleOnly` — the press cue and in-place
   ripple play with the screen untouched (no URL highlight at all), and the
   save then resolves as a mock shortcut run
   (`OnboardingShortcutRunEffects.swift`): the status bar fades OUT and a
   black capsule inflates around the real Dynamic Island the way the
   system's expanded treatment does — growing downward, taller and wider
   (340×76 from 126×37) — with the app icon on the left and a filling
   progress ring on the right; AS the island expands, the URL bubble pops
   out of its spot in the thread and flies a curved climb with a slight
   tumble, shrinking until the island swallows it (a raster copy flies so
   the tail comes along; the island puffs on absorption); a staged fingertip
   lands on the finished ring (the island squeezes under it); the island
   collapses and the status bar fades back; the app's action-extension
   presentation then plays as a mock sheet
   (`OnboardingActionExtensionSheetView`) sliding up over the dimmed
   conversation — grabber, Done chip, and the scrolling reader showing the
   same article the Safari mock cleaned up. The sheet's card is laid out
   with bounds+center, never `frame` — a layout pass mid-slide with a
   transform applied corrupted the geometry and made the dismiss "pop" —
   and it slides straight back down. While the sheet covers the screen, the
   absorbed bubble quietly returns to the thread. Then the follow-up
   outgoing message pops in: “Yeah just install this shortcut ⚡Luna” with
   the real Apple Shortcuts app icon (bundled `ShortcutsAppIcon.png`) on a
   purple-tinted pill that flows INLINE with the sentence — the pill is an
   `NSTextAttachment` placeholder in a UITextView with the live control
   seated over the attachment's laid-out rect, so line breaking stays
   natural. Half a second later a grey “or skip” button fades in under the
   composer, bottom-right (`onSkipSetup` → `finishOnboarding`). The
   demonstration stops there (`onShortcutSetupMessagesShown` advances the
   journey to `actionButtonSetup` and stops the loop). The Settings message
   — “And change your action button to that shortcut in ⚙Settings”, pill
   inlined the same way — arrives only after the user has been to the
   Shortcuts install and re-foregrounded the app
   (`revealSettingsSetupMessage`). Both pills glow and pulse until tapped —
   the shortcut pill runs the `BundledShortcut` installer, the Settings pill
   opens the Action Button settings.
6. Before Safari opens, onboarding installs the target's temporary save and
   lazily mounts the complete production root returned by that app's
   `AppOnboardingCompletion`. The final crossfade lands on that root
   carousel's exact centered card state; the live hierarchy is committed under
   the final composited frame.
   Reader, Downloader, Price Tracker, and central Luna therefore show their
   ordinary saved-card UI, chrome, scrubber, controls, and placement—not an
   onboarding remake or a Safari view clipped smaller.
7. Setup deliberately splits the demonstrations. The first Safari stage has no
   separate setup overlay: the mock extension-enable pass of step 3 ends on the
   switch flipping on, and THAT is the wipe's cue. `prepareCleanUp` (swapping
   each obstruction for still tiles, re-occluding the content, drawing every
   light raster) commits on the flip, the sheet then starts sliding away, and
   the sweep sets out with it — the top of the page is only dimmed by the
   sheet's fading scrim, never covered by its card, so the first shine still
   reads. The sweep itself always starts a run-loop turn after that
   heavy preparation commits — anchoring animations in the preparation's own
   turn let the commit outlive the short reveals at the top of the page, which
   then started already finished: at production speed the headline snapped in
   with no shine at all while the slower body bloomed correctly (the 6×
   `-slowOnboardingAnimations` run hid this entirely). For the same reason the
   `GlyphPixelBloomView` clock is anchored to its first display-link tick and
   the moon-reveal `CABasicAnimation`s carry no explicit `beginTime`.
   **Everything is cut from ONE front with zero offset and the front itself
   has no marker — no rim, no line, only its effect.** The front leaves the
   screen top at sweep start and descends at `height / 2.2s`; each element's
   occluder edge starts 1pt above its own top exactly as the front arrives
   and travels at exactly the front's speed
   (`revealFrontCrossingDistance / frontSpeed`), each obstruction tile
   detaches at the instant the front line reaches its center (scheduled
   through the same generation-guarded dispatch clock as the reveals — a
   pre-scheduled `UIView.animate(delay:)` counts from its own commit and ran
   a beat ahead), and the bloom's band position is slaved to the moon
   layer's *presentation* translation each display-link tick, so the light
   can never run ahead of or behind its own mask (a drifting clock is what
   made the text "appear, then brighten in chunks"). The reveal is EXACTLY
   the intro's — the same glyph-pixel bloom, with falloff distances scaled
   by the front's speed relative to the intro line's (~46pt/s reference), so
   every glyph brightens and cools over the same TIME as “You want to read
   more…” despite the ~9× faster sweep (the bloom renders just a strip
   around the edge, so article-length text sweeps at full frame rate). The
   images ride the same light pass: `MoonRevealImageView` feeds its own
   `GlyphPixelBloomView` a raster of the image as displayed whose alpha is
   rebuilt from LUMINANCE — Quartz shadows key off alpha, and an opaque
   photograph's black sky would otherwise glow like a full moon (note the
   masking rule: a grayscale masking image KEEPS samples where it is white,
   the opposite of true image masks) — at a lowered emitter gain (0.45) so
   only genuinely bright pixels (the NASA moons, the icon's dome and book)
   flare white-hot and cool back to their normal colors exactly like glyph
   strokes, along the image's whole height as the front crosses it. The
   setup card, sharing the screen, comes out of the same sweep from behind a
   page-coloured curtain (`MoonRevealCurtainView`, occluder only, no rim) —
   there is no scroll and the browser bar never moves.
   Only after the cleanup finishes does onboarding start the
   Safari PiP guide and open real Safari. If the extension has not run, return
   restores the in-page prompt for another attempt. Choosing “Skip for now”
   completes onboarding without opening Safari. A verified extension return —
   or the skip — hands off with the mock app-switcher hop
   (`transitionToMessagesViaAppSwitcher`): whatever is on screen slides out
   as a rounded card while the conversation, snapshotted at rest, slides in
   and fills the screen; there is no more URL-bar zoom or second save wave in
   Safari. The Messages replica then plays its
   three-bubble sequence, the Action Button press, and the full mock
   shortcut run of step 5a, ending in place on the pill message(s) — the
   shortcut and Action Button setup now lives in the conversation instead of
   an overlay. At the start of a press, the source URL gains a
   bright app-tint highlight; in Safari (Downloader/Price Tracker pages) it
   survives the blackout wave until the saved view replaces it, in Messages
   it holds through the island and extension-sheet mock. The setup actions
   retain the same `BundledShortcut`
   installer and `SystemSettingsLink.openActionButton()` paths and PiP guides.
   If Safari, Shortcuts, or Settings rejects the open request, the recovery
   instruction overlay appears (window-level, over whichever source is up) and
   offers every setup action. While present it is an accessibility modal and
   hides the mounted production hierarchy from assistive technologies. A
   return from the Shortcuts install reveals the Settings message (the
   shortcut pill's tail hands off to it); a return from Settings shows the
   “Press the action button to finish” overlay with its “Set up later”
   escape.
8. After Settings return, a real App Intent invocation completes the flow
   through `LunaSetupStatusStore.didChange`; “Set up later” reaches the same
   completion path.
9. Completion stops any active presentation and, unless it is already there, shrinks to the
   card once more. The real save and production root are already present, so it
   marks onboarding complete and crossfades the stationary production card into
   the fresh completed root—no eclipse or second geometry change. The payload
   is the fictional `luna.app` article for Reader and central Luna, local video for
   Downloader, and a real price tracker for Price Tracker.

With Reduce Motion enabled, Safari's full-screen Core Image wave is replaced by
a short source-to-saved-card crossfade; the Messages ripple is skipped (the
press cue alone carries the beat) and the island, tap, extension-sheet, and
app-switcher steps become plain fades. The two saves reuse one Core Image
context,
avoiding device-context and shader-cache setup between Safari and Messages.

The demonstration save is temporary — the mock content is never permanently
stored. Its exact UUID is recorded only when onboarding created a new item. It
exists for one reason: so the deck that replaces the journey isn't an empty
screen. Three things retire it, and its contents match the mock views exactly
(same title, same feature list, as real `.listItem` article structure) so the
card reads as the article the demonstration just saved:

- **The user's first real save**, immediately. `OnboardingDemoSaveEvictor` is
  armed the moment onboarding marks itself complete and watches every store this
  app saves into — `changeNotifications` + `storedIdentifiers` on
  `OnboardingTemporarySave`, which is why the central app and the Downloader
  name both `.readingListChanged` and `.savedMediaChanged` while Reader and Price
  Tracker name only the reading list. The watch is **id-based, not count-based**:
  it snapshots the stored ids when it arms, so content the user already had (a
  diagnostics onboarding reset leaves real saves in place) is not mistaken for a
  new one. The demonstration item disappearing on its own — a swipe-delete, the
  background cleanup — just ends the watch.
- **The first background callback** after onboarding completes, which deletes
  that exact save and its local media/image, then clears the UUID.
- **Launch**, which also sweeps a marker left by an abandoned or terminated run.

The save deliberately survives the incomplete onboarding background hops to
Safari, Shortcuts, and Settings because the production root needs it for each
replay. A pre-existing matching user save is never claimed or removed.

If iOS terminates an app while Safari or Settings is foreground, the next
launch starts incomplete onboarding from its first card; completion is not
inferred from merely opening a destination.

## Validation

Debug launches accept `-resetOnboarding` (`-resetReaderOnboarding` remains a
Reader alias). `-onboardingStage prompt|setup|waiting` moves through the real
direct card expansion and first shrink but begins at a deterministic overlay stage;
`-onboardingStage messages` opens straight onto the Messages replica and runs
its full demonstration (staged bubbles, ripple, Dynamic Island, app-switcher
hop, pill messages) for visual inspection.
`-readerOnboardingStage` remains an alias. Add `-slowOnboardingAnimations` for
a 6× inspection timeline, or `-onboardingAnimationScale <1...12>` for an
explicit factor. The clock slows Core Animation, timers, and the display-link
liquid wave together.

`ReaderOnboardingTests` covers independent per-app completion, exact surface
copy/page mapping, one feature list shared by every article surface,
temporary-save ownership, eviction on the first real save (and only on a real
one), idempotent offline article
installation, launch geometry, active-wave cancellation, the setup pills
(identifiers, glow-until-tapped, and their shortcut/Settings callbacks),
external-open fallback
actions, local-only HTML, bundled MP4 size, and attribution. The launch-art
recorder remains skipped in ordinary test runs.
