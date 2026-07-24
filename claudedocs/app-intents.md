# App Intents (`Luna/Mail/Intents/`)

The Action Button capture flow is **two intents** — `ProvideContextIntent` +
`SaveIntent` — plus `ReadArticleIntent` (background read-aloud via Siri, see
`claudedocs/audio-playback.md`'s "Siri" section). The intent structs live in the
app target (App Intents discovery requires it); all business logic lives in the
`LunaIntents` library, unit-tested behind pure functions and the vision seam.

> **Hard limit: an `AppShortcutsProvider` may list AT MOST 10 `AppShortcut`s.**
> Exceeding it is a HALTING build error in `appintentsmetadataprocessor` — and
> then NO AppIntents metadata is exported at all (every intent disappears from
> Shortcuts). `LunaShortcuts.appShortcuts` currently lists 3 (Provide Context,
> Save, Read Article).

To check what's actually registered, inspect the built metadata:
`Luna.app/Metadata.appintents/extract.actionsdata` (JSON; `autoShortcuts` = the
provider list, `actions` = all discoverable intents).

## The shortcut shape

**Get Current App + on-screen URL extraction → Provide Context(app, OnScreenURLs) →
If result.outcome = Requires Screenshot → Take Screenshot → Save(app, screenshot).**
No other branches. The old flow's magic return tokens
(`"open-luna"`, `"4:<url>"`) are gone — foregrounding happens in-intent (below)
and media download is coordinated by the intent that completes the save.

## `ProvideContextIntent` (`app: String?`, `onScreenURLs: String?`) → `ProvideContextResultEntity`

The return value is a `TransientAppEntity` with an `outcome:
ProvideContextOutcome` (`AppEnum`) and optional `media: IntentFile`. The outcome
is `.done`, `.unhandled`, or `.requiresScreenshot`; transient entities are result
values only and are not queryable.

Outside Safari, the optional **OnScreenURLs** input is checked first, before the
normal decision table **and before the onboarding interception**, so a supplied
URL this app can handle is saved even when the current app would otherwise be
unsupported. It is
deliberately a scalar String configured with
`.connectToPreviousIntentResult`, so Shortcuts can put the Get On-Screen URLs
magic variable in one text field instead of rendering a hand-authored collection
editor. Luna extracts every embedded HTTP(S) URL from bare, newline-delimited,
comma-delimited, or descriptive/JSON-like text before collapsing the candidates.
Empty input, non-HTTP(S) or
hostless URLs, whitespace-containing URLs, and values ending in `...`, `…`, or
`⋯` (including percent-encoded ellipsis) are ignored. Otherwise every element
must be a substring of the longest element; that longest complete URL is
chosen after ignoring an `http` versus `https` scheme difference (on-screen
detection commonly returns both forms for the same page).

`ProvideContextOnScreenURL.plan(text:isSafari:)` then turns the extraction into
one of three plans, and **pre-validation is what decides whether a later failure
is reported or ignored**:

| extraction | pre-check (`IntentURLPrecheck`) | plan |
|---|---|---|
| one candidate | predicted kind is handled by THIS app | **save** — and throw on any failure |
| one candidate | predicted kind belongs to a sibling app, or unusable URL | **skip** — silent fall-through |
| ≥2 distinct valid, non-collapsing URLs | at least one is handleable | **divergent** — throws `multipleURLs` (after the onboarding hijack: an in-flight setup run must still advance) |
| ≥2 distinct valid URLs | none handleable | **skip** |
| nothing usable | — | **skip** |

`IntentURLPrecheck.verdict(for:current:)` classifies URL-ONLY
(`Classifier.classify(url:)`, no fetch) and maps the predicted `ContentKind` to
its owning app (`.undetermined` → article, matching where the pipeline sends a
plain page), then runs `SurfaceSupport.evaluate`. A `.save` plan goes through the
same immediate-URL save function used by the Safari-extension fast path and
returns `.done` (with synchronous media when applicable). Because the pre-check
already said this app handles the kind, a foreign-kind rejection from the REAL
classification (an undetermined page that turned out to be a product) throws
instead of being swallowed. A save timeout remains handled because the normal
ingest task continues and persists pending work for retry.

The shared **Settings → Shortcut & Safari → Handle On-Screen URLs** toggle is on
by default. Turning it off makes `ProvideContextIntent` ignore the `OnScreenURLs`
input entirely and continue through the same onboarding and app/screenshot
decision it would use when no URL was supplied. The preference is stored in the
App Group through `AppIntentSettings`, so the settings UI and background intent
execution always read the same value across all three apps.

When no usable on-screen URL was supplied, the **onboarding hijack** runs:
`ActionButtonOnboardingStore.shared
.handleProvideContextInvoked(appName:isCurrentAppLuna:forSurface:)` gets the
invocation before app classification (see "Action Button onboarding" below).
`.foregroundThenUnsupported` → foreground Luna, return `.unhandled`;
`.unsupported` → return `.unhandled`; `.none` → proceed.

Then the pure decision table (`LunaIntents.ProvideContextDecision.decide`,
evaluated top to bottom; table-driven tests in `ProvideContextDecisionTests`):

| `app` | conditions | result |
|---|---|---|
| nil / empty (lock screen) | — | **unhandled** |
| Safari | `SafariURLStore.isFresh()` (URL present, ≤ 72 h) | **done** — saves `lastURL` NOW via the action-button path |
| Safari | URL stale/absent, vision model available | **requiresScreenshot** |
| Safari | URL stale/absent, no vision model | **unhandled** |
| Shortcuts (outside onboarding) | — | **unhandled** (no meaningful screenshot of Shortcuts' own UI) |
| Platform app (tiktok/instagram/x/facebook/bluesky/reddit) | this app doesn't handle media | **unhandled** |
| Platform app | handles media, no vision model | **unhandled** |
| Platform app | handles media, vision model available | **requiresScreenshot** |
| Unrecognized | — | **unhandled** |

Inputs: `AppNamePlatform.{isSafari,isShortcuts,platform}(forAppName:)`;
`handlesMediaKind` = `AppSurfaceConfig.current.handlesMedia` (Downloader or the
central Luna app — a sibling never hands off cross-app anymore);
`visionModelAvailable` = `ScreenCaptureModelSessionFactory.makeDefault()
.isAvailable`. The immediate Safari save (1) goes through
`IntentIngestHelper.handleSavePress` with the Reader-only double-save surface
armed (see `double-save.md`). Because `.done` bypasses `SaveIntent`,
`ProvideContextIntent` also sends a downloadable tracked Safari URL through the
shared permission-aware Downloader handoff before returning. With **Return
Downloaded Media** on (the default), it resolves the content length and checks storage.
A known file up to 100 MiB runs through the Live Activity/background engine and is
awaited so the completed static image/GIF/video can be attached as `media`; larger or
unknown files start the same durable transfer and return `media = nil` immediately.
With the setting off, every file uses that immediate background handoff. A friend-prompt
outcome foregrounds Luna.

## `SaveIntent` (`app: String`, `screenshot: IntentFile`) → `SaveResultEntity`

The return value is a `TransientAppEntity` with optional `media: IntentFile`.
Non-media saves and background-download mode return `media = nil`.

1. **Digest double-press skip** — `ScreenshotDigest.digest(forImageData:)`
   (32×32 grayscale, CoreGraphics-only) vs `ScreenshotDoublePressStore.last()`
   (App-Group single-slot: digest + date + saved URL).
   `ScreenshotDoublePress.decide` treats a visually-similar screenshot within
   `SavePressPolicy.intentDoublePressWindow` (7 s) as an Action Button
   double-press: **no model call** — the previous save is re-run so the
   configured double-save action fires (Kindle / friend / prompt), and the
   snapshot timestamp is refreshed. `ScreenshotDigest.similarityThreshold`
   still needs on-device tuning against status-bar clock/Dynamic Island noise.
2. Otherwise: prompt = `AppNamePlatform.safariScreenPrompt` ("title ; site")
   for Safari, else the per-platform `screenPrompt(forAppName:)`; run
   prompt+image through the vision seam (below); parse with
   `SaveResponseParsing.parseFields` (" ; " split, "none"/empty → no fields →
   `nothingIdentifiable`).
3. Route: Safari → `SafariPageSave.save(title:site:...)` (quoted-title
   DuckDuckGo search, non-article-host filter, first survivor — known-fuzzy,
   flagged for device QA); platforms → `PlatformFieldSave.save(platform:
   fields:...)` (bluesky = handle+phrase via `BlueskyPostQuery`, reddit =
   subreddit+title+author? via `RedditPostQuery`, x/tiktok/instagram/facebook =
   handle+phrase+date? via `SocialPostFinder`). Both are double-save-aware and
   return `IntentIngestHelper.ActionButtonSaveOutcome`, whose cases carry the
   saved URL string.
4. The save awaits its classified outcome (bounded by the 12-second race) so a
   failure can be reported, then the row is verified against the store. If the
   RUNNING app handles media (Downloader / central Luna) and the URL is downloadable,
   the intent performs exactly one media handoff regardless of per-platform toggles.
   `AppIntentSettings.returnsMediaToShortcuts` is App-Group-backed and defaults on (its
   user-facing inverse is **Download in Background** under Settings ▸ Shortcut & Safari):
   it reuses an already-downloaded local/Photos-backed
   item when present, otherwise resolves the content length and checks available storage.
   A known file at or below 100 MiB is awaited through `LiveMediaDownloadManager` and
   returned as an `IntentFile`; larger/unknown files and all setting-off invocations call
   `MediaAutoDownloader.startDownloaderIntentDownload` and return nil while the Live
   Activity/background transfer continues. Reader, Downloader, and Price Tracker each embed
   the shared Live Activity widget source. Synchronous results are materialized at a
   temporary URL whose last path component is a sanitized saved-item title (or platform
   base name such as `tiktok.mp4`) and use the concrete file UTI, so downstream Share
   actions preserve a valid extension instead of exposing the durable UUID storage name.
   The platform finder's resolved URL is carried separately from the save outcome, so a
   duplicate/double-save timeout cannot suppress the media handoff.
   Downloader's shared “Save Downloads to Photos” preference is honored: an undetermined
   read/write permission request foregrounds the invoking app first; denial falls back to
   the shared local media library. Insufficient space throws a user-facing intent error
   before transfer. A `friendPromptRequested` outcome also foregrounds Luna.
5. Errors are thrown as `SaveError: CustomLocalizedStringResourceConvertible`
   (`unsupportedApp`, `unsupportedKind`, `modelUnavailable`, `networkUnavailable`,
   `quotaLimitReached`, `serviceUnavailable`, `nothingIdentifiable`,
   `notFound`, `saveFailed`, `contentUnavailable`). Both save legs — the
   screenshot route and the double-press re-save — go through one
   `savedURLString(from:)` mapping, so neither can report success over a
   vanished or failed item. The happy path returns `SaveResultEntity`.

## Error reporting (the no-silent-failure invariant)

**An intent must never report success while the app holds nothing, or holds only
a failure.** A Shortcut that exits cleanly with an empty list (the classic case:
no download and nothing saved) is a bug, not a degraded success. So every save an
intent *believed in* is verified, and every way it can end empty throws:

- **What "believed in" means.** Safari's fresh tracked URL always counts. An
  on-screen URL counts when `IntentURLPrecheck` predicts a kind this app
  handles (above). A screenshot save counts when the current app is one we have
  a screen prompt for and the model returned parseable fields. Anything else is
  not a save attempt at all and stays silent.
- **Verification** (`IntentSaveVerification`, run inside
  `IntentIngestHelper.handleSavePress`): after the press, the store is re-read by
  ITEM ID — the id survives an unwrap repoint, the URL doesn't — and the item's
  state decides. `.ready`/`.pending` pass; `.failed` → `contentUnavailable`; a
  missing item → `nothingSaved`. **`.needsCaptcha` PASSES**: a hard-paywalled
  article is saved, titled, behind the tap-to-unlock affordance — a successful
  save, not a failure. A placeholder that is gone because it DEDUPED into an
  existing item (wrapper resolved to an article already in the list, store URL
  merged into an existing tracker) also passes; the content is in the app under
  the surviving item. `handleSavePress` reports the outcome as
  `.saveFailed(_)`, and `.completed`'s URL is the item's CURRENT one, so media
  handoff uses the resolved URL rather than the wrapper.
- **Timeouts stay successes.** The 12-second race expiring means the ingest is
  still running and its item is in the store as `.pending`; it finishes or is
  retried on the next launch. There is nothing to verify and nothing to report.
- **Media** (`media-download.md`): the handoff throws when the transfer engine
  reports that nothing is downloading and nothing will be. Already-downloaded
  and Wi-Fi-deferred are no-file successes.
- **`ProvideContextError`**: `noTrackedPage`, `unsupportedKind`, `multipleURLs`,
  `saveFailed`, `contentUnavailable`.

## The vision seam (compiler + availability double gate)

FoundationModels' image input (`Attachment`, `PromptRepresentable`) and
`PrivateCloudComputeLanguageModel` are **iOS 27.0-only and completely absent
from iPhoneOS26.2.sdk**, so all vision/PCC code is double-gated behind the
seam in `LunaIntents`:

- `ScreenCaptureModelSession` (protocol + `ScreenCaptureModelError` +
  always-unavailable stub) — ungated, unit-testable with fakes.
- `FoundationModelsScreenCaptureSession` — whole file `#if compiler(>=6.4)`,
  class `@available(iOS 27.0, *)`. PCC model when available (vision-capable),
  else the on-device `SystemLanguageModel` when it has `.vision`.
- `ScreenCaptureModelSessionFactory.makeDefault()` — the ONE place the gate
  lives; everything above it sees only the protocol.

**Consequence:** App Store builds archived with stable Xcode 26.2 compile the
stub, so `visionModelAvailable` is false and **screenshot capture is unhandled in
released builds until archives move to Xcode 27 GM**. The Safari fresh-URL
path (`.done`) works everywhere. Dev builds (Xcode 27 beta) on an iOS 27
device with Apple Intelligence enabled get the full flow.

## Foregrounding

Both intents conform to `ForegroundContinuableIntent` and call
`requestToContinueInForeground()` (suspends, foregrounds the app, then the
intent continues and returns its result). It's deprecated in iOS 26 in favor
of `supportedModes: IntentModes` + `continueInForeground()`, but remains
functional (introduced 16.4, present in both SDKs); one code path beats mixing
the two mechanisms on the same intent type. Used for: the onboarding
bounce-back, and the double-save "ask every time" friend prompt —
`ReadingListIngestor` records the pending prompt, the intent foregrounds, and
`SceneDelegate.applyPendingFriendPrompt()` presents `SendToFriendSheet`.

## Action Button onboarding (`LunaStorage.ActionButtonOnboardingStore`)

The iOS 27+ Action Button is set up by importing the bundled `Send To
Luna.shortcut` and assigning it to the Action Button in Settings. Both
`ProvideContextIntent` invocations that happen DURING this setup — one from
the Shortcuts app's own first run, one from wherever the Action Button is
actually pressed — are hijacked before any decision work.
`AppNamePlatform.isShortcuts(forAppName:)` recognizes the first of these
("Shortcuts" is otherwise `.unhandled`).

`ActionButtonOnboardingStore` (`LunaLibraries/Sources/LunaStorage/`) is a
per-surface (`AppSurface.storageIdentifier`: `"reader"`/`"downloader"`/
`"pricetracker"`) state machine persisted in App Group `UserDefaults`
(`onboarding.actionButtonState.<surface>`), driven by:
- `SceneDelegate.sceneWillEnterForeground` / `AppDelegate.applicationDidEnterBackground`
  → `handleAppForegrounded`/`handleAppBackgrounded` (track the Luna↔Shortcuts↔Settings
  round trip),
- the onboarding UI → `beginInstallStep` / `markSettingsDeeplinkTapped`,
- `ProvideContextIntent.perform()` →
  `handleProvideContextInvoked(appName:isCurrentAppLuna:forSurface:)`, called
  before any decision work. It returns a `ProvideContextInterception`:
  `.foregroundThenUnsupported` (foreground Luna in-intent, then return `.unhandled` — the
  freshly-imported shortcut's first run, or real setup completing while another
  app was frontmost), `.unsupported` (return `.unhandled` without foregrounding — Luna is
  already frontmost; the in-app UI reacts to
  `ActionButtonOnboardingStore.stateDidChangeNotification` instead), or `.none`
  (no interception — the normal decision flow proceeds).

`SystemSettingsLink.openActionButton()` deep-links Settings → Action Button
(`App-Prefs:root=ACTION_BUTTON`, falling back through the same private-scheme
cascade as `open()`).

## Bundled shortcut + user setup

`Luna/Resources/Send To Luna.shortcut` is an AEA1-signed `.shortcut` bundle
(display name = `BundledShortcut.displayName`). Settings → "Install Shortcut"
(`BundledShortcut.presentInstaller`) shares the bundled file to the Shortcuts
app (`shortcuts://import-workflow?url=` REJECTS local file URLs, so install
stays share-sheet based).

> **Manual step (signed file, cannot be generated by this codebase): the
> bundled shortcut must be re-authored by hand** in the Shortcuts app to the
> new shape — Get Current App + on-screen URL extraction → Provide
> Context(app, OnScreenURLs) → If result.outcome is Requires Screenshot → Take
> Screenshot → Save(app, screenshot) — exported, renamed to
> `Send To Luna.shortcut`, and dropped into `Luna/Resources/`. This is a
> **clean break**: old installs (the Screen Analysis Prompt / Save from App
> chain) reference deleted intents and must be reinstalled via Settings →
> Install Shortcut.

User setup:
1. Enable the Safari extension (see `safari-extension.md`) — feeds
   `SafariURLStore` for the no-screenshot Safari save.
2. Settings → Install Shortcut → share to Shortcuts → Add Shortcut. First run
   prompts to allow sharing app info with Luna; choose Always Allow.
3. Settings → Action Button → Shortcut → pick "Send To Luna".

The Action Button shortcut setup section is hidden below iOS 27. Action Button
can't be assigned programmatically; the simulator has no Action Button (test
by running the shortcut from the Shortcuts app). On-device QA still owed: real
Action Button run on an iOS 27 device (FM vision/PCC can't run in CI sims),
digest threshold tuning, and the fuzzy Safari title→search save across sites.

The Live Activity widget's Suspend/Resume intents
(`LunaMediaDownload.LiveMediaDownloadManager`) are a separate flow, untouched
by the capture intents.

> **ITMS-90626**: an App Intent `title`/`description`/parameter string must NEVER
> contain "apple" or Siri references, or App Store processing silently drops the
> build. (Doc comments, `.apple` enum cases, and `itunes.apple.com` URLs in code
> are fine — only the AppIntents metadata strings are scanned.)
