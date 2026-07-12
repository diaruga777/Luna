# Onboarding flow — steps, state machine, PiP guide videos

`Luna/Social/OnboardingFlow.swift` builds the first-launch flow for all three apps
(each onboards once per app, per-app `SceneDelegate.onboardingCompleteKey`, with a
"Replay Onboarding" row in Settings). Steps are `OnboardingStepViewController`
(`LunaLibraries/Sources/LunaSocialUI/`), chained by closures onto a bare
`UINavigationController`.

## Step order

1. **Email** (`emailStep` / `existingAccountStep`, index 0) — skippable; connects
   the email account send/receive shares run through. When the shared account is
   already configured — metadata in App-Group defaults, secret in the shared
   App-Group keychain access group (`CredentialKeychain.sharedAccessGroup`), so a
   sign-in in ANY of the three apps counts — `OnboardingFlow.make` collapses the
   whole flow to the single `existingAccountStep` ("Email already connected" →
   Finish), skipping the login and the Safari/Action-Button steps.
2. **Safari extension** (`safariStep`, index 1) — animation `.safariExtension`.
   "Open Safari" sets the Safari takeover-pending flag, starts the Safari guide
   video's PiP, and opens a Wikipedia URL so the user can exercise the extension
   from Safari's page menu (aA → Manage Extensions → Luna on).
3. Branches here:
   - **iOS 27+, once the Safari extension has run at least once**:
     **shortcut install**
     (`shortcutInstallStep`, index 2) → **Action Button setup**
     (`actionButtonStep`, index 3). 4 steps total.
   - **Pre-27, or iOS 27 before the Safari extension has reported that it ran**:
     a single final **action extension** step (`actionExtensionStep`, index
     `totalSteps - 1`) explaining the Share-sheet "Save to Luna" action. 3 steps
     total (this is the path exercised on the iOS 26.2 sim, since
     `#available(iOS 27.0, *)` is false there at runtime).

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
- `LunaSafari`'s native handler records `safariExtensionHasRun.<surface> = true`
  for every native message it receives, because any native message proves the
  extension is enabled and has run at least once. It also keeps writing the legacy
  `safariExtensionEnabled.<surface>` timestamp for diagnostics/backward
  compatibility. The explicit `onboardingStatus` message still consumes a pending
  takeover one-shot and tells the page to show the "You're all set! / Back to
  Luna" overlay (see `claudedocs/safari-extension.md`).
- Back in Luna, `onWillEnterForeground` stops the PiP and, if
  `SafariExtensionStatusStore.shared.isEnabled(forSurface:)` is now true, advances
  the flow automatically — the same routing "Continue" would take. A `didAdvance`
  flag guards against double-advancing if both the foreground callback and a
  manual "Continue" tap fire.
- Advancing (by either path) always clears `takeoverPending` first.

## Action Button state machine (`LunaStorage.ActionButtonOnboardingStore`)

See `claudedocs/app-intents.md` for the full state machine
(`notStarted → installTapped → awaitingShortcutRun → actionButtonSetup →
awaitingActionButton → done`) and how `ProvideContextIntent` intercepts
invocations during setup. The onboarding UI drives/observes it as follows:

- **`shortcutInstallStep`**: "Install Shortcut" → `beginInstallStep` +
  `BundledShortcut.presentInstaller`. "Continue" → `setState(.actionButtonSetup)`
  then advances. It also observes
  `ActionButtonOnboardingStore.stateDidChangeNotification` (`object: surface`) and
  `onWillEnterForeground`: whenever the state reaches `.actionButtonSetup` *and*
  this step is still the topmost view controller, it auto-pushes
  `actionButtonStep` (once — a `didAdvance` flag, and the notification observer is
  torn down on advance). This covers both ways `.actionButtonSetup` gets set: the
  freshly-imported shortcut's own first run (from the Shortcuts app, via
  `handleProvideContextInvoked`), or the one-shot "installed but never ran it" skip
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

- **`init` is trivial by design; the whole AV stack is lazy.** The step factories
  construct an `OnboardingGuideVideo` at step-creation time — i.e. inside the
  *previous* step's button handler — and building the
  `AVPlayerItem`/`AVPlayerLooper`/`AVPictureInPictureController` there used to
  visibly stall the push transition (the "enormous delay" from the email step to
  the Safari step). Everything is now created on first `play()` (from the step's
  own `viewDidAppear`) / `startPictureInPicture()` instead. Loads a bundled mp4
  (one matching pair per app surface, such as
  `Luna/Resources/SafariExtensionGuideDownloader.mp4`) into an `AVQueuePlayer`
  with `AVPlayerLooper`. Do NOT set
  `player.actionAtItemEnd` — `AVPlayerLooper` requires the default (`.advance`);
  overriding it to `.none` freezes playback at the end of the first pass. And do
  not rebuild a long `AVMutableComposition` here, because that can leave PiP
  showing only a static poster if the user taps "Open Safari" / "Open Settings"
  quickly.
- `playerView` (an `AVPlayerLayer`-backed view) is installed **behind** the live
  `OnboardingAnimationView` illustration via
  `OnboardingStepViewController.installBackdropView(_:)` — small (40×40) and
  centered, fully covered by the illustration's opaque phone mockup. It must NOT
  be pinned to the animation's full frame: the illustrations are transparent
  around the mockup, so a full-size video peeks out around the edges and reads as
  garbled overlapping UI. Small-and-covered keeps it invisible (and snapshot
  tests deterministic) while still counting as on-screen-and-playing for AVKit's
  PiP hand-off (PiP always shows the full video content regardless of the source
  layer's size). `installBackdropView` is idempotent — `onDidAppear` fires on
  every re-appear and must not stack duplicate installs/constraints.
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

The clips are recorded from the SAME `OnboardingAnimationView` UIKit elements and
animations used inline (`.safariExtension` for the Safari clip;
`.actionButtonSettings` — a fixed-dark mock of Settings → Action Button built
specifically for this), via `LunaTests/GuideVideoRecorderTests.swift`. The recorder
generates both clips for Reader, Downloader, and Price Tracker, so PiP carries the
same app icon as the live UI. It is gated behind `RECORD_GUIDE_VIDEOS=1` (mirrors
the `RECORD_SNAPSHOTS` pattern in `SnapshotTesting.swift`; `XCTSkip`s otherwise).
It hosts the animation at its own fixed intrinsic size in a scene-attached window,
waits out the animation's start-up delay, then drives a `CADisplayLink` for exactly one
`OnboardingAnimationView.Kind.loopDuration`, rendering each tick's
`layer.presentation()` (NOT the model layer — this is what captures the
in-flight `CAKeyframeAnimation` values rather than their static end state) into
an `AVAssetWriter` H.264 mp4 at ~30fps 2x pixel scale (Safari: 220×360 → 440×720;
Action Button: 280×300 → 560×600 — even dimensions, required for H.264), ~800kbps.

Three implementation notes that matter if you touch this:
- **The recording `UIWindow` MUST be attached to a `UIWindowScene`**
  (`UIWindow(windowScene:)`, taking the test host app's foreground scene). A
  scene-less window is never committed to the render server, so its CAAnimations
  never advance and `presentation()` just mirrors the static model tree — the
  recorder then silently produces a "video" of one frozen frame repeated for the
  full duration (this exact bug shipped once). The recorder now asserts
  `distinctFrameCount > 10` after writing so a static capture fails the test
  instead of landing in `Luna/Resources/`.
- Rendering uses `CALayer.render(in:)`, **not**
  `drawHierarchy(in:afterScreenUpdates:)` — `SnapshotTesting.swift` already
  established that `drawHierarchy` produces blank captures for off-screen test
  windows on this runtime; `render(in:)` doesn't have that problem.
- `render(in:)` draws into Core Graphics' native bottom-up coordinate space,
  which is flipped relative to the top-down space UIKit lays the view tree out
  in — the pixel-buffer context must be flipped (`translateBy` + `scaleBy`, which
  also applies the 2x content scale) before calling `render(in:)`, or the
  recorded frames come out upside down / mirrored. The 2x is context scale, not a
  view `transform` — a scaled view in an Auto Layout window shifts its frame and
  crops the capture.

### Build-time regeneration

Each app target has a **Record onboarding PiP guides** build phase immediately
before Copy Bundle Resources. The phase runs the test recorder only for **Debug
iOS Simulator** builds and only if either:

- `LunaLibraries/Sources/LunaSocialUI/OnboardingAnimationView.swift` changed; or
- one of the six surface-specific clips is missing.

Its source hash is stored in
`Luna/Resources/.onboarding-guide-video-source.sha256`. A lock makes parallel
Reader/Downloader/Price Tracker builds share one recording session. The nested
test build gets `LUNA_GUIDE_VIDEO_RECORDING=1`, which makes its own build phase a
no-op and prevents recursion. Device and Archive builds deliberately use the
last known-good videos; this avoids a simulator test during signing/archive.

If no iOS 26+ simulator is booted, or the recorder fails, the phase emits a
warning and preserves the existing clips. Start a compatible Simulator and build
again, or run the recorder manually:

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
  Luna/Resources/SafariExtensionGuide{Reader,Downloader,PriceTracker}.mp4 \
  Luna/Resources/ActionButtonGuide{Reader,Downloader,PriceTracker}.mp4
```

`LUNA_SKIP_GUIDE_VIDEO_RECORDING=1` skips the automatic phase for one local
build. `OnboardingGuideVideo` falls back to the old unsuffixed Reader clips when
a new surface-specific clip is unavailable, so PiP stays functional while a
manual re-record is pending.

## Illustration app icons (`AppIconImage<App>` imagesets)

`OnboardingAnimationView.AppIcon` picks the current app's icon for the mock UI
rows (Dynamic Island confirmation, "Save to Luna" share row, Safari extension
toggle row, notification banner) by bundle-id suffix. The recorder can inject all
three identities explicitly, which is why the generated PiP clips also retain
surface-specific branding. It loads the
`AppIconImageReader` / `AppIconImageDownloader` / `AppIconImagePriceTracker`
imagesets in `Luna/Assets.xcassets` — **not** the `AppIcon*` appiconsets, because
`.appiconset`s are not loadable via `UIImage(named:)`; before these imagesets
existed the lookup silently fell back to the unrelated `luna-app-mark` glyph.
The canonical Home Screen icons live in `SharedIconAssets.xcassets` as standard
Xcode 26-compatible `AppIconReader`, `AppIconDownloader`, and
`AppIconPriceTracker` appiconsets. Keep the three onboarding images in sync with
their corresponding `*-1024.png` canonical exports (all downscaled to 512).

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
  user would. `shouldUseActionButtonFlowAfterSafari(forSurface:)` also treats an
  already-enabled baseline as eligible for the iOS 27 shortcut/action-button
  screens during replay, so a configured app can still experience those steps
  again.
- **Action Button replay bridge**: lifecycle callbacks (`AppDelegate`) and
  `ProvideContextIntent` run outside the onboarding view controller and always talk to
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
codebase cannot regenerate. It must be re-authored and re-exported by hand in
the Shortcuts app whenever the intents change — **owed right now for the
two-intent flow** (see `claudedocs/app-intents.md`): Get Current App → Provide
Context(app) → If result = 2 → Take Screenshot → Save(app, screenshot). No
other branches — the old "open-luna"/"4:<url>" token branches are gone
(foregrounding and auto-download happen in-intent). Export it, rename to
`Send To Luna.shortcut`, and drop it into `Luna/Resources/` (same
filesystem-synchronized group as the guide videos above). This is a clean
break: previously-installed copies reference deleted intents and must be
reinstalled via Settings → Install Shortcut.
