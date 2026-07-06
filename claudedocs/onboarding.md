# Onboarding flow — steps, state machine, PiP guide videos

`Luna/Social/OnboardingFlow.swift` builds the first-launch flow for all three apps
(each onboards once per app, per-app `SceneDelegate.onboardingCompleteKey`, with a
"Replay Onboarding" row in Settings). Steps are `OnboardingStepViewController`
(`LunaLibraries/Sources/LunaSocialUI/`), chained by closures onto a bare
`UINavigationController`.

## Step order

1. **Email** (`emailStep` / `existingAccountStep`, index 0) — skippable; connects
   the email account send/receive shares run through. Unchanged by this work.
2. **Safari extension** (`safariStep`, index 1) — animation `.safariExtension`.
   "Open Safari" sets the Safari takeover-pending flag, starts the Safari guide
   video's PiP, and opens a Wikipedia URL so the user can exercise the extension
   from Safari's page menu (aA → Manage Extensions → Luna on).
3. Branches here:
   - **iOS 27+**: **shortcut install**
     (`shortcutInstallStep`, index 2) → **Action Button setup**
     (`actionButtonStep`, index 3). 4 steps total. This route no longer depends
     on the Safari extension's App Group "enabled" marker being freshly written:
     that marker can lag if the user enabled the extension before onboarding or
     has not opened a new page since toggling it on, but iOS 27 users still need
     the shortcut/action-button setup.
   - **Pre-27**: a single final **action extension** step
     (`actionExtensionStep`, index `totalSteps - 1`) explaining the Share-sheet
     "Save to Luna" action. 3 steps total (this is the path exercised on the iOS
     26.2 sim, since `#available(iOS 27.0, *)` is false there at runtime).

`totalSteps` is a computed property (`4` under `#available(iOS 27.0, *)`, else
`3`) rather than a stored constant, since the branch is a runtime check.

The `shortcutInstallStep`/`actionButtonStep` factory functions themselves carry
**no** `@available` annotation — only the *call sites* that route into them check
iOS 27 availability at runtime. That means they build (and snapshot) fine on any
OS; `OnboardingFlow.stepViewControllersForTesting()` (`#if DEBUG`) returns all five
distinct step kinds — email, Safari, shortcut install, Action Button, action
extension — for test coverage, even though only 3 or 4 of them appear in any one
real run.

## Safari takeover handshake

Enabling a Safari extension is a real out-of-app round trip, unlike the in-app
Settings deep links used elsewhere in this flow. The state lives in
`LunaStorage.SafariExtensionStatusStore` (App Group `UserDefaults`, per-surface):

- The onboarding step sets `setTakeoverPending(true, forSurface:)` as soon as it
  appears (`onDidAppear`) and again when "Open Safari" is tapped — either is
  enough; both are harmless/idempotent.
- `LunaSafari`'s native handler (`SafariWebExtensionHandler` → `onboardingStatus`
  message, backed by `SharedOnboardingStatus.recordEnabledAndConsumeTakeover()`)
  records that the extension is enabled the first time `background.js` asks (at
  script load) and, if a takeover was pending for that surface, consumes it
  one-shot and tells the page to show the "You're all set! / Back to Luna"
  overlay (see `claudedocs/safari-extension.md`).
- Back in Luna, `onWillEnterForeground` stops the PiP and, if
  `SafariExtensionStatusStore.shared.isEnabled(forSurface:)` is now true, advances
  the flow automatically — the same routing "Continue" would take. A `didAdvance`
  flag guards against double-advancing if both the foreground callback and a
  manual "Continue" tap fire.
- Advancing (by either path) always clears `takeoverPending` first.

## Action Button state machine (`LunaStorage.ActionButtonOnboardingStore`)

See `claudedocs/app-intents.md` for the full state machine
(`notStarted → installTapped → awaitingShortcutRun → actionButtonSetup →
awaitingActionButton → done`) and how `SaveFromAppIntent` intercepts saves during
setup. The onboarding UI drives/observes it as follows:

- **`shortcutInstallStep`**: "Install Shortcut" → `beginInstallStep` +
  `BundledShortcut.presentInstaller`. "Continue" → `setState(.actionButtonSetup)`
  then advances. It also observes
  `ActionButtonOnboardingStore.stateDidChangeNotification` (`object: surface`) and
  `onWillEnterForeground`: whenever the state reaches `.actionButtonSetup` *and*
  this step is still the topmost view controller, it auto-pushes
  `actionButtonStep` (once — a `didAdvance` flag, and the notification observer is
  torn down on advance). This covers both ways `.actionButtonSetup` gets set: the
  freshly-imported shortcut's own first run (from the Shortcuts app, via
  `handleSaveIntentInvoked`), or the one-shot "installed but never ran it" skip
  (`handleAppForegrounded`, fired from `SceneDelegate.sceneWillEnterForeground`).
- **`actionButtonStep`**: "Open Settings" → `markSettingsDeeplinkTapped` + starts
  the Action Button guide PiP + `SystemSettingsLink.openActionButton()`. "Done" →
  `setState(.done)` and finishes onboarding. It observes the same notification for
  `.done` (stops PiP, finishes — guarded once) and `onWillEnterForeground` (stops
  PiP; nudges the body copy to "Press the Action Button to continue." once state
  reaches `.awaitingActionButton` or later).
- The intent may drive `.done` two different ways relative to foregrounding: while
  Luna is already frontmost (in-process — the notification fires immediately), or
  right as the Shortcut's "Open App → Luna" branch relaunches Luna into the
  foreground (the app process was never killed while backgrounded — its
  `NotificationCenter` observer is still alive — so the notification, posted just
  before relaunch, is still received). Both orderings are covered by the single
  notification observer; no separate foreground-time `.done` check is needed.
  (Intents in this project run in the app's own process — there's no separate
  intents-extension target — which is what makes same-process `NotificationCenter`
  delivery a valid mechanism here.)

## PiP guide videos (`Luna/OnboardingGuideVideo.swift`)

`OnboardingGuideVideo` wraps a small, muted, looping "how to" clip:

- Loads a bundled mp4 (`Luna/Resources/SafariExtensionGuide.mp4` /
  `Luna/Resources/ActionButtonGuide.mp4`) into an `AVQueuePlayer` with
  `AVPlayerLooper`. The bundled files stay tiny (tens of KB) and the player is
  ready immediately; do not rebuild a long `AVMutableComposition` here, because
  that can delay the next onboarding page and leave PiP showing only a static
  poster if the user taps "Open Safari" / "Open Settings" quickly.
- `playerView` (an `AVPlayerLayer`-backed view) is installed **behind** the live
  `OnboardingAnimationView` illustration via
  `OnboardingStepViewController.installBackdropView(_:)` — pinned to the
  animation's frame, fully covered by it, so it's invisible while the step is on
  screen (keeps snapshot tests deterministic) but still actually playing.
- `AVPictureInPictureController.canStartPictureInPictureAutomaticallyFromInline =
  true`, so backgrounding the app from that step auto-starts PiP; `startPictureInPicture()`
  is also called programmatically right before the "leave Luna" button
  (Open Safari / Open Settings) opens its URL, so PiP is already active by the
  time the user actually leaves. `stopPictureInPicture()` is called on
  `onWillEnterForeground` and whenever the step is left. All PiP calls guard on
  `AVPictureInPictureController.isPictureInPictureSupported()` /
  `isPictureInPicturePossible` and silently no-op otherwise (PiP support is
  inconsistent on the Simulator — this must never crash or block the flow).
- `AVAudioSession` is configured `.playback` + `.mixWithOthers` when playback
  starts (not at load time) — needed for PiP to keep playing once the app is
  backgrounded. The `audio` UIBackgroundMode is set for all three targets via the
  shared `Config/Luna.xcconfig` (`INFOPLIST_KEY_UIBackgroundModes = audio`) rather
  than per-target — it's a project-level base config (see the two lines near the
  top of that file referencing `Luna.xcconfig` as `baseConfigurationReference`),
  so it reaches `Luna`/`LunaDownloader`/`LunaPriceTracker` for free; it's inert on
  the extension targets, which never start playback.

### Regenerating the guide videos

The clips are recorded from the SAME `OnboardingAnimationView` illustrations used
inline (`.safariExtension` for the Safari clip; `.actionButtonSettings` — a
fixed-dark mock of Settings → Action Button built specifically for this — for the
Action Button clip), via `LunaTests/GuideVideoRecorderTests.swift`. Gated behind
`RECORD_GUIDE_VIDEOS=1` (mirrors the `RECORD_SNAPSHOTS` pattern in
`SnapshotTesting.swift`; `XCTSkip`s otherwise). It hosts the animation at 2x its
own fixed intrinsic size (e.g. Safari: 220×360 → 440×720; Action Button:
280×300 → 560×600 — both even dimensions, required for H.264), waits out the
animation's own start-up delay, then drives a `CADisplayLink` for exactly one
`OnboardingAnimationView.Kind.loopDuration`, rendering each tick's
`layer.presentation()` (NOT the model layer — this is what captures the
in-flight `CAKeyframeAnimation` values rather than their static end state) into
an `AVAssetWriter` H.264 mp4 at ~30fps, ~800kbps (clips land under ~50KB in
practice — well under the ~2MB budget).

Two implementation notes that matter if you touch this:
- Rendering uses `CALayer.render(in:)`, **not**
  `drawHierarchy(in:afterScreenUpdates:)` — `SnapshotTesting.swift` already
  established that `drawHierarchy` produces blank captures for off-screen test
  windows on this runtime; `render(in:)` doesn't have that problem.
- `render(in:)` draws into Core Graphics' native bottom-up coordinate space,
  which is flipped relative to the top-down space UIKit lays the view tree out
  in — the pixel-buffer context must be flipped (`translateBy` + `scaleBy(1, -1)`)
  before calling `render(in:)`, or the recorded frames come out upside down /
  mirrored.

Regenerate with (see CLAUDE.md for the `DEVELOPER_DIR` requirement and simulator
UDIDs):

```sh
DD=<a derivedDataPath>
SIM=<a booted iOS 26.x simulator UDID>
TEST_RUNNER_RECORD_GUIDE_VIDEOS=1 TEST_RUNNER_GUIDE_VIDEO_OUTPUT_DIR=/Users/hsp/Desktop/Luna/Luna/Resources \
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app xcodebuild test -scheme Luna \
  -destination "platform=iOS Simulator,id=$SIM" -configuration Debug -derivedDataPath "$DD" \
  DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO \
  -only-testing:LunaTests/GuideVideoRecorderTests
```

**The `TEST_RUNNER_`-prefixed variables must be set as real shell environment
variables on the `xcodebuild` invocation itself** (`VAR=1 xcodebuild …`) — passing
them as trailing `KEY=value` arguments (the way you'd override a build setting)
does **not** reach the test runner's process environment; only variables actually
present in `xcodebuild`'s own environment, prefixed `TEST_RUNNER_`, get forwarded
(prefix stripped) to the host running the tests. This applies equally to
`RECORD_SNAPSHOTS` (`SnapshotTesting.swift`) despite CLAUDE.md's existing
recipe reading as if the CLI-argument form works — it doesn't, under this
environment's `xcodebuild`; the shell-prefix form does.

After regenerating, sanity-check the outputs (they land directly in
`Luna/Resources/`, a filesystem-synchronized Xcode group shared by all three app
targets, so no project-file changes are needed to pick them up):

```sh
ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 \
  Luna/Resources/SafariExtensionGuide.mp4 Luna/Resources/ActionButtonGuide.mp4
```

## Replay ("Replay Onboarding" in Settings)

Settings → "Replay Onboarding" (`Luna/Settings/SettingsViewController.swift`) runs the
**entire** flow — including the email login sub-flow — through `OnboardingStores`, so
it behaves like a fresh install and remains fully traversable/testable from Settings.

- Every step builder in `OnboardingFlow` now takes an `OnboardingStores` (`Luna/Social/
  OnboardingStores.swift`) instead of reaching `EmailAccountStore.shared` /
  `SafariExtensionStatusStore.shared` / `ActionButtonOnboardingStore.shared` directly.
  `OnboardingFlow.make(stores:onFinished:)` defaults to `OnboardingStores.real` (the
  three real singletons — normal first-launch behavior, unchanged).
- The Settings row instead builds `OnboardingStores.ephemeral()`: email account
  metadata and Safari status are backed by one scratch `UserDefaults(suiteName:
  "onboarding.replay.<UUID>")`, plus an in-memory stand-in
  (`LunaMailAccount.InMemoryCredentialStorage`) for the email credential in place of
  the Keychain (`EmailAccountStore`'s new `credentialStorage:` seam —
  `MailCredentialStorage` — defaults to a `KeychainCredentialStorage` wrapping the
  same `CredentialKeychain` calls it always made, so `.shared`'s behavior is
  unchanged). `EmailLoginFlow.present`/`EmailEntryViewController`/
  `CredentialViewController` all take an injected `EmailAccountStore` (default
  `.shared`) so a "sign in" during a replay saves into the overlay, not the Keychain.
- **Safari read-through rule**: the real Safari extension is a separate process the
  replay can't sandbox, so `OnboardingStores.isSafariExtensionEnabled(forSurface:)`
  snapshots the REAL enabled state as a baseline when the ephemeral instance is
  created, then reports enabled once the scratch overlay itself is set OR the real
  value newly flips true relative to that baseline. A replay always starts looking
  fresh even if the extension was already enabled before the replay began, but a user
  who genuinely turns it on mid-replay still advances the flow like a first-time
  user would. iOS 27 routing now goes to the shortcut/action-button screens
  regardless of this marker; the read-through rule remains useful for foreground
  auto-advance and replay fidelity.
- **Action Button replay bridge**: lifecycle callbacks (`AppDelegate`) and
  `SaveFromAppIntent` run outside the onboarding view controller and always talk to
  `ActionButtonOnboardingStore.shared`, so a scratch action-button store cannot
  observe the real shortcut/action-button round trips. `OnboardingStores.ephemeral()`
  snapshots the current real per-surface Action Button state, temporarily sets it to
  `.notStarted`, and then points the replay at the real store. The replay can now
  transition through install → foreground skip → settings → intent completion like
  first-run onboarding; `stores.tearDown()` restores the snapshot before the modal is
  dismissed.
- `stores.tearDown()` restores any temporarily re-armed Action Button state and then
  removes the scratch suite with `removePersistentDomain(forName:)`. The onboarding
  root has no cancel affordance and is presented `.fullScreen` (not interactively
  dismissible), so finishing the flow is the normal exit path.

## Manual follow-up (cannot be automated)

The bundled `Luna/Resources/Send To Luna.shortcut` is a **signed** file this
codebase cannot regenerate. If the shortcut's steps ever need to change (e.g. to
match a new `ActionButtonOnboardingStore.openLunaToken` value, or new intent
parameters), it must be re-authored and re-exported by hand in the Shortcuts app:
branch on the Save From App result equalling `"open-luna"` → "Open App → Luna";
otherwise fall through to whatever the result string implies (e.g. a `"4:"`-prefixed
result offers a download — see `claudedocs/app-intents.md`). Export it, rename to
`Send To Luna.shortcut`, and drop it into `Luna/Resources/` (same
filesystem-synchronized group as the guide videos above).
