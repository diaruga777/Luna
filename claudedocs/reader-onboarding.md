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

- Safari opens the surface-specific `luna.app`/InstaTok/amayzon teaching page,
  shows the extension effect, then guides the user to Safari extension setup.
- Save setup uses the Messages replica and selects the Action Button shortcut
  journey or share/action-extension journey from
  `OnboardingSurfaceConfiguration.saveSetupMode`.
- external-open recovery overlays remain available if Safari, Shortcuts, or
  Settings rejects a route.
- Reduce Motion replaces waves and switcher choreography with short fades.

Completing or choosing the lesson's skip/later path both call
`completeSetupFlow`. Safari records `markSafariSetupHandled`; Messages/save setup
records `markSaveSetupHandled`. If both are now finished, the explicit completion
marker is also written. The lesson dismisses back to the same production root and
does not replace the carousel.

The setup demonstrations remain storage-free: their mock article, video, and
product never enter `readingList.json` or any content directory. The legacy
temporary-demo cleanup remains only for users updating from an older build.

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
- `ReaderOnboardingTests`: per-app markers and central inheritance;
- the existing onboarding visual/lesson tests: copy, setup effects, recovery,
  local assets, storage-free demos, Reduce Motion, and launch geometry.
