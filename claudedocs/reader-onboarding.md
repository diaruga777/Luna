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
   three actions appear as a vertical stack: **Remove popups and walls for
   me** with Safari's compass, **Save on-screen links with the Action Button**
   with the bundled Shortcuts icon, and a real `UIPasteControl` labelled
   **Paste a url**. The setup buttons use a restrained 24% wash of the current
   app surface tint; completing either lesson replaces its icon with a
   checkmark and disables/greys that action. The intro card remains black and
   contains no icon cluster or supporting copy. A new UIKit corona
   independently reconstructs the splash's static peak behind this initial card
   for the entire intro; neither the launch raster nor its overlay hierarchy is
   retained.
2. The Safari and Shortcut actions are independent lessons. Either leaves the
   intro through `OnboardingAppSwitcherView`: the intro deck shrinks and exits
   left while the chosen Safari or Messages replica enters from the right and
   fills the screen. Finishing or skipping that lesson runs the same transition
   back to the intro and checks only its originating button; it never chains
   into the other lesson and never completes onboarding. The replicas, guide
   players, and an empty production root warm in separate run-loop turns after
   the first line reveal, but this preload does **not** install demo content.
   The temporary demonstration save is installed only after a setup button is
   pressed, and its destination snapshot is captured lazily when the mock save
   wave actually needs it. Paste-first onboarding therefore leaves the shared
   store untouched.
3. The Reader's Safari content is a native, fictional `luna.app` article so its
   sequence begins after the card finishes expanding rather than during hidden
   preload. The page loads ALREADY BURIED: four garish ads, the newsletter
   popup, and the subscription wall are all in place from the first frame (no
   entrance animations), over an article — headline, byline, NASA eclipse
   banner, and a body that FILLS the page and runs past the fold; the setup
   card floats over the content and no scroll is ever needed. That body is a
   **bulleted list of what Luna actually does** (clutter and paywall removal,
   offline copies, the speed reader, read-aloud, exports, price tracking and
   the rest) rather than marketing prose — the article is the demonstration's
   only chance to say what the app is for. The copy lives once
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
6. Setup demonstrations still install the target's temporary save so their
   mock save can land on the real production card. The production root itself
   is already mounted empty behind the intro; installing the demo item reloads
   it in place, and the save-wave raster is captured only when requested.
   Returning from a lesson leaves that temporary item available for the other
   lesson, but does not mark onboarding complete.
7. Setup deliberately splits the demonstrations. The first Safari stage has no
   separate setup overlay: the mock extension-enable pass of step 3 ends on the
   switch flipping on, and THAT is the wipe's cue. `prepareCleanUp` (swapping
   each obstruction for still tiles, re-occluding the content, drawing every
   light raster) commits on the flip, the sheet then starts sliding away, and
   the sweep sets out with it — the top of the page is only dimmed by the
   sheet's fading scrim, never covered by its card, so the first shine still
   reads. The cascade itself always starts a run-loop turn after that
   heavy preparation commits — anchoring animations in the preparation's own
   turn let the commit outlive the first reveals, which then started already
   finished (verify wipe timing at 1×, e.g. `simctl io recordVideo` + frame
   analysis, and remember the `-skipNotificationAuthPrompt` DEBUG arg so the
   permission alert doesn't sit over the recording; a 6×
   `-slowOnboardingAnimations` run hides commit-latency bugs entirely).
   **THE ARTICLE IS THE INTRO'S ANIMATION, ELEMENT BY ELEMENT — a wave that
   CLIMBS the page.** `computeCascade` gives every element its own intro
   reveal with the moon geometry MIRRORED (`sweepsUpward` on
   `MoonRevealLineView`/`MoonRevealImageView`; the shared classes default
   to the intro's descending sweep, which stays byte-identical): the body
   — whose copy deliberately fills the page past the fold — ignites first
   from the page bottom, then the eclipse image, byline, and finally the
   icon+headline row, each element's edge rising at `cascadeFrontSpeed`
   (140pt/s; the bloom's falloff bands stretch with the ratio so every
   glyph's brighten-and-cool takes exactly the intro's TIME). A fast
   unified single front was tried repeatedly and always read as garbage
   next to the intro — the per-element cascade at intro-derived pacing is
   the shape that works. Each element sets out when the one below it is
   `cascadeOverlap` through; there is no marker on any edge — no rim, no
   line, only the light. Each obstruction tile (~11pt grains, with a
   0–33ms trailing-only scatter) detaches at the instant the climbing
   light beneath its center arrives — `FrontLeg`s map page-y to arrival
   time, and a running maximum from the page bottom UP keeps detachment
   strictly bottom-to-top — batched into one dispatch turn per frame-width
   of delay. **The setup card takes no part in the wave**: it floats over
   the page content (there is no card slot below the body any more), and
   once the wave finishes it materialises top-to-bottom under its own
   bloom — a mask geometrically excludes its unrevealed part so the page
   shows through, an empty prober layer rides the same translation to
   drive the light, and its luminance raster makes the explainer text and
   button flare exactly like glyphs; the corona fades in only once the
   card is whole (fading it alongside outlined the card's silhouette
   before the surface existed). The Manage Extensions sheet's own
   choreography is brisk: present 0.3s, toggle after 0.3s, dismiss 0.25s. The images ride the
   same light pass: `MoonRevealImageView` feeds its own
   `GlyphPixelBloomView` a raster of the image as displayed whose alpha is
   rebuilt from LUMINANCE — Quartz shadows key off alpha, and an opaque
   photograph's black sky would otherwise glow like a full moon (note the
   masking rule: a grayscale masking image KEEPS samples where it is white,
   the opposite of true image masks) — at a lowered emitter gain (0.45) so
   only genuinely bright pixels (the NASA moons, the icon's dome and book)
   flare white-hot and cool back to their normal colors exactly like glyph
   strokes. The setup card comes out last from behind a page-coloured
   curtain (`MoonRevealCurtainView`, occluder only, no rim, capped at
   `curtainMaxDuration` since it carries no light) — there is no scroll and
   the browser bar never moves. Its two buttons are
   INERT until that sweep finishes: the clutter burying the card is
   non-interactive, so a tap at the card's position would otherwise reach a
   button nobody can see — and during the opening app-switcher hop it would
   drop the setup leg (`skipSafariSetupAndContinue` bails while a hop is in
   flight).
   Only after the cleanup finishes does onboarding start the
   Safari PiP guide and open real Safari. If the extension has not run, return
   restores the in-page prompt for another attempt. Choosing “Skip for now” or
   returning with verified extension evidence finishes the Safari lesson and
   app-switches back to the intro with its button checked. The Shortcut action
   independently opens the Messages replica, which plays its three-bubble
   sequence, the Action Button press, and the full mock shortcut run of step
   5a, ending in place on the pill message(s). At the start of a press, the
   source URL gains a
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
8. After Settings return, a real App Intent invocation reports through
   `LunaSetupStatusStore.didChange`; “Set up later” reaches the same Shortcut
   lesson completion path. Both app-switch back to the intro and check/disable
   the Shortcut button. Neither setup lesson completes onboarding.
9. The paste row is the completion action. `UIPasteControl` supplies the value
   without a paste-permission alert. Luna unwraps and runs the shared classifier
   before writing: non-URL and non-article outcomes turn the row red with
   **article URLs only**; extraction/network/persistence failures turn it red
   with **unable to load page**. A successfully extracted article is saved,
   the temporary demo item (if any) is removed, and a fresh production root is
   laid out around that real card. The onboarding carousel temporarily gains a
   snapshot of the real saved card to its right and pages there through the
   production `CardEclipseTransition`; after egress the pixel-matched live root
   replaces it, leaving the ordinary left tray where the onboarding card's peek
   had been. A new shared-store identifier observed while the intro card is up
   (share/action extension or App Intent) follows the same completion semantics
   without inventing a tap-origin eclipse. Saves made while a mock lesson is up
   are folded into the baseline when that lesson returns, so the lesson still
   returns to the three-action intro as promised.

With Reduce Motion enabled, Safari's full-screen Core Image wave is replaced by
a short source-to-saved-card crossfade; the Messages ripple is skipped (the
press cue alone carries the beat) and the island, tap, extension-sheet, and
app-switcher steps become plain fades. The two saves reuse one Core Image
context,
avoiding device-context and shader-cache setup between Safari and Messages.

The demonstration save is temporary — the mock content is never permanently
stored. Its exact UUID is recorded only when onboarding created a new item, and
its contents match the mock views exactly so each lesson's save lands on the
article/video/tracker it just showed. It survives the incomplete Safari,
Shortcuts, and Settings hops and the app-switcher return to the intro, because
the other independent lesson may still use it. A pasted or externally observed
real save removes the demo synchronously before the completed root is built;
launch also sweeps a marker left by an abandoned run. A pre-existing matching
user save is never claimed or removed.

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

`ReaderOnboardingTests` covers independent per-app completion, the three intro
actions and hit-testing, exact surface
copy/page mapping, one feature list shared by every article surface,
temporary-save ownership, external-save completion, idempotent offline article
installation, launch geometry, active-wave cancellation, the setup pills
(identifiers, glow-until-tapped, and their shortcut/Settings callbacks),
external-open fallback
actions, local-only HTML, bundled MP4 size, and attribution. The launch-art
recorder remains skipped in ordinary test runs.
