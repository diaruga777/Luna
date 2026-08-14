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

**Get Current App + on-screen URL extraction → Provide Context(CurrentApp,
OnScreenURLs) → branch on result.outcome:**

- **Done / Unhandled:** stop. `Media` is only meaningful for Done.
- **Screenshot:** Take Screenshot, then
  `Save(CurrentApp, screenshot, result.Metadata)`.
- **Download:** do not take a screenshot; run
  `Save(CurrentApp, nil, result.Metadata)`.

Provide Context is intentionally a normal `AppIntent`. Save is the only
`LongRunningIntent`, so the system's progress UX appears only for real downloads,
prepared double-save work, or a normal save that approached its time limit.

## `ProvideContextIntent` (`currentApp: String?`, `onScreenURLs: String?`) → `ProvideContextResultEntity`

The transient return value has exactly three properties:

1. `media: IntentFile?` — optional and only returned with `.done` (including a
   locally available media file or a completed double-save document export).
2. `outcome: ProvideContextOutcome` — `.done`, `.screenshot`, `.download`, or
   `.unhandled`.
3. `metadata: String?` — versioned opaque JSON, present only for `.screenshot`
   and `.download`.

`CaptureIntentMetadata` currently records schema version, phase (`screenshot`,
`save`, `download`, or `comparison`), CurrentApp, resolved URL, the atomically
decided double-save flag, a `SavesIngestor.PreparedSavePress`, and (when
resolved) the direct `MediaAsset` plus expected byte count. Decode failure is
deliberately treated as no metadata; Save then runs from the top. The string is a
transport checkpoint, not Shortcut-facing API.

**Schema versions: every version up to the current one decodes; a newer one does
not.** The schema is additive by rule — v2 added `Phase.comparison` and nothing
else — so a v1 checkpoint sitting in a Shortcut across an app update still
describes a save that is genuinely resumable, and refusing it would silently
restart work the user already waited through. A value from a FUTURE version is
refused, because its phase may name work this build cannot perform.

**The product leg (`comparison`).** In the two price-tracking apps a product
save's own `media` is the alternative-seller summary document
(`claudedocs/price-comparison.md`) — one self-contained HTML file, returned
through the same `IntentFile` seam as a double-save article export.

**The intents are the one surface that still WAITS for the fan-out**, because
their whole answer is a comparison between the sellers it finds. Everywhere else
the save lands immediately and the run goes out in the background; here
`ProductIntentHandoff.document` joins the run before rendering
(`SellerComparison.complete`, a rendezvous — an extension's run already in flight
is awaited rather than duplicated, and it clears the pending marker either way,
so the launch and refresh sweeps do not repeat it). The wait needs no plumbing of
its own: it happens inside the SUMMARY race — join the fan-out, refresh any
seller whose price is over a day old, build the file — and on expiry that becomes
a `comparison` checkpoint, resumed under Save's extended runtime. The whole leg hangs off
`ActionButtonIntentSupport.productComparisonDocument`, installed by
`ProductIntentHandoff` (the product twin of `MediaIntentHandoff`, compiled only
into the two product apps), so Reader and Downloader never look for one.

**A sibling Luna app in the foreground outranks everything below.** All four apps
register both intents, so a press made while another app in the family owns the
screen can reach any of them; there is nothing there to save (the sibling's own
UI is not a page, and a link visible inside it is already in the shared store,
filed under the app that owns its kind). `AppNamePlatform.isSiblingLunaApp` is
checked before the OnScreenURLs input and before the decision table:
`ProvideContextIntent` returns `.unhandled` and `SaveIntent` returns an empty
`SaveResultEntity` — no save, no error dialog, no screenshot. The frontmost name
is compared against every `LunaApp.displayName` as a WHOLE normalized name,
because "Luna" is a prefix of the other three; the running app itself is
deliberately not a match, so a press inside the app you're holding keeps whatever
its own screen affords. `SiblingLunaAppIntentGateTests` pins the matrix.

The optional **OnScreenURLs** input is checked next, before the normal decision
table (including in Safari), so a supplied
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
| ≥2 distinct valid, non-collapsing URLs | at least one is handleable | **divergent** — throws `multipleURLs` |
| ≥2 distinct valid URLs | none handleable | **skip** |
| nothing usable | — | **skip** |

`IntentURLPrecheck.verdict(for:current:)` classifies URL-ONLY
(`Classifier.classify(url:)`, no fetch) and maps the predicted `ContentKind` to
its owning app (`.undetermined` → article, matching where the pipeline sends a
plain page), then runs `SurfaceSupport.evaluate`. A `.save` plan goes through the
same immediate-URL save function used by the Safari-extension fallback. Because the pre-check
already said this app handles the kind, a foreign-kind rejection from the REAL
classification (an undetermined page that turned out to be a product) throws
instead of being swallowed.

The whole immediate-URL path has one **20-second deadline**. Before asynchronous
work, `prepareSavePress` atomically reserves the URL and freezes the policy
decision in a Codable state. The fast path then unwraps, classifies, fetches,
persists, and (for media) resolves the asset/redirect, performs the HEAD size
check, and validates storage. It never starts a media transfer. If it finishes:

- non-media → `.done`;
- already-local media → `.done` with `Media`;
- downloadable media → `.download` with a prepared media checkpoint.

If the deadline wins, the work task is cancelled, `SavesIngestor` refuses
to persist the cancelled result, and the pending placeholder + frozen decision
are returned as `.download` Metadata. Save waits for cancellation cleanup and
resumes that same prepared state; it does not reserve another press. Non-trivial
double-save actions also route directly to Save after their immediate atomic
decision so a timed-out send/export can never execute twice.

The shared **Settings → Shortcut & Safari → Handle On-Screen URLs** toggle is on
by default. Turning it off makes `ProvideContextIntent` ignore the `OnScreenURLs`
input entirely and continue through the same app/screenshot
decision it would use when no URL was supplied. The preference is stored in the
App Group through `AppIntentSettings`, so the settings UI and background intent
execution always read the same value across all three apps.

With no usable on-screen URL supplied, the pure decision table decides (`LunaIntents.ProvideContextDecision.decide`,
evaluated top to bottom; table-driven tests in `ProvideContextDecisionTests`):

| `app` | conditions | result |
|---|---|---|
| another Luna app | — (gated in the intent, above the table) | **unhandled** |
| nil / empty (lock screen) | — | **unhandled** |
| Safari | `SafariURLStore.isFresh()` (URL present, ≤ 72 h) | **done or download** — prepares/saves `lastURL` now |
| Safari | URL stale/absent, no extension has ever run | **unhandled** |
| Safari | URL stale/absent, an extension has run, vision model available | **screenshot** |
| Safari | URL stale/absent, an extension has run, no vision model | **error** ("no tracked page") |
| Shortcuts | — | **unhandled** (no meaningful screenshot of Shortcuts' own UI) |
| Platform app (tiktok/instagram/x/facebook/bluesky/reddit) | this app doesn't handle media | **unhandled** |
| Platform app | handles media, no vision model | **unhandled** |
| Platform app | handles media, vision model available | **screenshot** |
| Unrecognized | — | **unhandled** |

The Safari rows split on `safariExtensionHasRun`
(`LunaSetupStatusStore.anySafariExtensionHasRun`) because the two situations are
not the same failure. Nobody has ever enabled the extension ⇒ nothing was in a
position to capture the page, so the Shortcut just stops — a first-run user gets
no error dialog for a feature they haven't set up. An extension HAS run ⇒ assume
it is still enabled, so a missing page URL in Safari is a real failure and is
reported as one (the screenshot route, when a model is available, reports its own
failure instead).

That evidence — like the tracked URL itself — is **read opportunistically across
all four apps**. Every app's Safari extension writes the one shared
`lastSafariURL` in the one App Group (`SafariURLStore.record`, from
`background.js`'s kind-agnostic active-tab report), and the app reads it back
from that same store, so the Downloader's extension supplies the Reader's Action
Button and vice versa. `anySafariExtensionHasRun` matches by ORing both
completion markers rather than asking `safariRunApplies(to:)`, whose per-app
answer is deliberately narrower: an in-page pill can only deep-link into its OWN
containing app, so onboarding completion is not shared sideways even though the
URL is.

Inputs: `AppNamePlatform.{isSafari,isShortcuts,platform}(forAppName:)`;
`handlesMediaKind` = `LunaApp.current.handlesMedia` (Downloader or the
central Luna app — a sibling never hands off cross-app anymore);
`visionModelAvailable` = `ScreenCaptureModelSessionFactory.makeDefault()
.isAvailable`. Screenshot outcomes carry a seed checkpoint (CurrentApp, no URL
yet). Immediate URLs use the prepared state described above.

## `SaveIntent` (`currentApp: String`, `screenshot: IntentFile?`, `metadata: String?`) → `SaveResultEntity`

The return value is a `TransientAppEntity` with optional `media: IntentFile`.
Non-media saves and large/unknown media downloads return `media = nil`. Empty or
invalid Metadata preserves the old behavior: with a screenshot, Save performs
screen analysis and all save work from the top; without either usable input it
throws `nothingIdentifiable`.

Before screenshot handling, Save decodes Metadata:

- `save` resumes the exact `PreparedSavePress`, waiting for a cancelled Provide
  Context task to leave the per-item in-flight set first;
- `download` skips ingest and starts from the saved URL plus optional media
  checkpoint, avoiding repeated asset resolution and HEAD work;
- `comparison` skips ingest entirely — the product and its alternative sellers
  are already saved — and only builds the summary document, with room to refresh
  day-old seller prices first;
- `screenshot` deliberately falls through to screen analysis.

A resumed `save` also produces a comparison document when the saved URL turns out
to be a tracked product; that replaces the media handoff for the run, exactly as
a double-save export does.

`media` carries one other thing: when **Double Save Articles** (same article URL
twice within 7 s) is configured as **View immediately**, a self-contained DOCX
article document is returned there instead, and the media handoff is skipped for
that run. See double-save.md.

0. **Sibling Luna app gate** — first, and specifically ahead of the double-press
   skip below, which would otherwise re-run the previous save without ever
   consulting the current app. Returns an empty `SaveResultEntity`.
1. **Digest double-press skip** — `ScreenshotDigest.digest(forImageData:)`
   (32×32 grayscale, CoreGraphics-only) vs `ScreenshotDoublePressStore.last()`
   (App-Group single-slot: digest + date + saved URL).
   `ScreenshotDoublePress.decide` treats a visually-similar screenshot within
   `SavePressPolicy.intentDoublePressWindow` (7 s) as an Action Button
   double-press: **no model call** — the previous save is re-run so configured
   Kindle receives it (or nothing happens when Kindle is not configured), and the
   snapshot timestamp is refreshed. `ScreenshotDigest.similarityThreshold`
   still needs on-device tuning against status-bar clock/Dynamic Island noise.
   Every intent captures its attempt timestamp at the start of `perform()`. Once
   a URL resolves, `SavesStore.reserveSaveAttempt` atomically inserts it and
   its explicit `lastSaveAttemptDate`, or updates the existing marker, before
   ingest. Save's screenshot slot is also committed as one App-Group value at
   URL resolution, before ingest/fetch. At the end, the intent recommits both
   markers with completion time; the still-running ingest task does the same if
   it outlives an intent timeout. The seven-second window is therefore live from
   start during work and from completion afterward. Zero-gap and reverse-arrival
   overlaps count without a minimum threshold.
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
4. The save awaits its classified outcome (bounded by `captureSaveTimeout` — see
   "Runtime + progress UI") so a
   failure can be reported, then the row is verified against the store. If the
   RUNNING app handles media (Downloader / central Luna) and the URL is downloadable,
   the intent performs exactly one media handoff. It reuses an already-downloaded local/Photos-backed
   item when present, otherwise resolves the content length and checks available storage.
   A known file at or below 100 MiB is awaited through `LiveMediaDownloadManager` and
   returned as an `IntentFile`; larger/unknown files call
   `MediaAutoDownloader.startDownloaderIntentDownload` and return nil while the Live
   Activity/background transfer continues (which activity shows depends on the runtime —
   see "Runtime + progress UI"). Reader, Downloader, and Price Tracker each embed
   the shared Live Activity widget source. Synchronous results are materialized at a
   temporary URL whose last path component is a sanitized saved-item title (or platform
   base name such as `tiktok.mp4`) and use the concrete file UTI, so downstream Share
   actions preserve a valid extension instead of exposing the durable UUID storage name.
   The platform finder's resolved URL is carried separately from the save outcome, so a
   duplicate/double-save timeout cannot suppress the media handoff.
   The shared “Save Downloads to Photos” preference is honored: an undetermined
   read/write permission request foregrounds the invoking app first; denial falls back to
   the shared local media library. Insufficient space throws a user-facing intent error
   before transfer.
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
- **Provide Context timeouts become resumable work.** At 20 s the fast-path task
  is cancelled, its result is not persisted, and `.download` Metadata carries
  the prepared reservation/decision to Save. Save resumes and verifies normally.
- **Media** (`media-download.md`): the handoff throws when the transfer engine
  reports that nothing is downloading and nothing will be. Already-downloaded
  and Wi-Fi-deferred are no-file successes.
- **`ProvideContextError`**: `noTrackedPage`, `unsupportedKind`, `multipleURLs`,
  `saveFailed`, `contentUnavailable`.

## Runtime + progress UI (`CaptureIntentRuntime*.swift`)

The split is by intent, not by content surface:

| intent/file | targets | runtime | save-press wait |
|---|---|---|---|
| `ProvideContextIntent` | all four | normal `AppIntent`, ordinary ~30 s system budget | one 20 s whole-fast-path deadline |
| `SaveIntent` / `CaptureIntentRuntime.swift` fallback | all four | inline when built/run without the iOS 27 APIs | `IntentSaveTimeout.standard` (12 s) for screenshot saves |
| `SaveIntent` / `CaptureIntentRuntime+LongRunning.swift` | all four | `LiveActivityIntent` + `LongRunningIntent` + `CancellableIntent` | `.extendedRuntime` (`IngestPipeline.processTimeout + 2` = 30 s) |

The synchronized-group exclusions for the long-running runtime were removed from
Reader and Price Tracker because a slow article/product save can now be handed
off too. `MediaIntentHandoff.swift` remains excluded from non-media apps, and
`PriceTracker/ProductIntentHandoff.swift` from non-product ones.

`IntentProgressReporter.Stage` gained `findingSellers`, which shares
`downloading`'s wide band rather than splitting it: a save is a product or it is
media, never both in sequence, so splitting would make each look half as far
along as it is. Verify
built metadata with an Xcode 27 build: Provide Context must not list the
long-running/session-starting protocols; Save must list them in every app.

Both protocols are orthogonal refinements of `AppIntent` (SDK headers:
`LiveActivityIntent : SystemIntent`, `LongRunningIntent : ProgressReportingIntent`,
both empty), so one type adopts both, and extension-declared conformances DO
survive metadata extraction (that's what the `SessionStarting` check above
confirms).

**`LiveActivityIntent` (iOS 17+, no gate — below the iOS 18 target).** On Save,
this
is what PERMITS a Live Activity to start from a background Action Button run at
all: *"In general, your app needs to be in the foreground to start a Live
Activity. However, you can use a `LiveActivityIntent` and start the Live Activity
in its `perform()` method."* Before adopting it, `Activity.request` threw for
every background capture and `startActivity` swallowed it into the diagnostic log
(`"live activity request failed"`) — the download ran with no UI, which is what a
Shortcut exiting over an invisible download looked like. Verify with the extracted
metadata: `systemProtocols` for Save must list
`com.apple.link.systemProtocol.SessionStarting` next to `…ForegroundContinuable`.

**`LongRunningIntent` (iOS 27, double-gated, Save only).** Without an
extension an app intent gets **~30 s** in the background (Apple's figure, stated
in `LongRunningIntent`). Provide Context opportunistically uses only 20 s of that
ordinary budget and hands off; Save owns extended execution. Gates:

- `#if compiler(>=6.4)` — the protocol is **absent from iPhoneOS26.2.sdk** (0
  occurrences in its `AppIntents` swiftinterface vs 2 in the iOS 27 SDK), so a
  stable-Xcode archive must not name it. Same seam shape as
  `FoundationModelsScreenCaptureSession`. **Release builds archived with Xcode
  26.2 therefore run the fallback path**, exactly as they compile the vision stub.
- `@available(iOS 27, *)` on the conformance and on every `performBackgroundTask`
  call site.

Apple documents **no ceiling** for the extended runtime — it lasts as long as you
keep reporting progress and the system tolerates it, and the user can cancel it.
So progress is mandatory, not decoration: *"If you don't update this property
regularly, the system can cancel the background runtime extension and end your
task prematurely."* `IntentProgressReporter` supplies it — three stages
(`saving` 0–0.02, `downloading` 0.02–0.99, `finishing` 0.99–1.0); real transitions
snap the value to the next band's floor, a 1 s heartbeat closes 12 % of the
remaining distance to the current band's ceiling. Deliberately an estimate: an
indeterminate `Progress` that never moves is what gets cancelled. Never let a tick
cross into the next band — a save still running must not read as a download.

**The fast-path budget is separate from the Save budget.** Provide Context uses
`IntentSaveTimeout.provideContext` (20 s) around save plus media preparation.
Save's screenshot-from-top fallback still threads `captureSaveTimeout` through
`SafariPageSave` / `PlatformFieldSave`; under extended runtime it is
`IngestPipeline.processTimeout + 2`, while the stable-SDK fallback remains 12 s.
Checkpoint resume itself does not re-race the save: the LongRunning operation
waits for the cancelled task to unwind and finishes the pipeline.

**`CancellableIntent`** (iOS 26.4 — also absent from the 26.2 SDK, so it shares the
`#if compiler(>=6.4)` gate) unlocks `performBackgroundTask`'s `onCancel:`
overload, so the two ways a run ends early are distinguishable and logged:
`.userCancelled` (dismissed from the system's progress UI) and `.timeout` (the
system reclaimed the runtime). The handler is SYNCHRONOUS and fires while the
runtime is being revoked, so it only records; it deliberately does NOT stop the
transfer, which is a durable Downloader job that also feeds the library. Instead
the awaited media leg notices `Task.isCancelled` and calls
`LiveMediaDownloadManager.resumeOwnProgressUI(forSourceURLString:)` on the way
out — handing the progress UI back to Luna's own Live Activity (which carries an
explicit Suspend control), so a download that keeps running never goes invisible.

**Which Live Activity shows.** Prefer the system's:

| leg | iOS 27 + Xcode 27 build | otherwise |
|---|---|---|
| awaited download (file returned) | system intent progress UI; Luna's suppressed | Luna's own Live Activity |
| background/deferred transfer | Luna's own (the system's ends with the intent) | Luna's own |

Suppression is `LiveMediaDownloadManager.systemProvidesProgressUI`, a
**task-local** bound by `MediaIntentHandoff` (media apps only, so it can read
`CaptureIntentExtendedRuntime.isAvailable`) around the awaited call only — so a
concurrent in-app save keeps its own activity and there's no global flag to leave
set. It is deliberately NOT bound around the background leg: that transfer
outlives the intent, and the system's progress UI does not.

`LongRunningTaskOptions` is left empty — `requiresGPU` is the only option and
none of this work touches the GPU.

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
the two mechanisms on the same intent type. Used for: the double-save
"ask every time" friend prompt —
`SavesIngestor` records the pending prompt, the intent foregrounds, and
`SceneDelegate.applyPendingFriendPrompt()` presents `SendToFriendSheet`.

## Action Button setup

The Action Button — iOS 27 **and** hardware that has one — is set up from the
permanent util card and can be replayed from Settings. Its first state imports the app's own
bundled shortcut; once opened, the setup action assumes installation and
becomes “One more step! Set your action button to {App Name}.” Open Settings
starts the per-surface PiP guide and opens Settings at its root. The action remains
until either Action Button App Intent records completion, at
which point the running app receives the cross-process status notification,
stops PiP, and checks/disables the action for the rest of the session. The compact
completed util-card layout appears on the next launch. Current builds attribute both the import
press (`setup.shortcut.installPressed.<surface>`) and intent run
(`setup.shortcut.hasRun.<surface>`) to the exact Luna app. The import flag means
only “the installer button was pressed”; iOS does not reveal whether Add
Shortcut completed. Shared run evidence can satisfy the save-setup leg for
sibling Luna surfaces.

The guide is an anonymous instructional mock, not a capture of a real device.
Its Settings beat begins at Cellular and follows the system ordering through
Display & Brightness; it contains no account, Wi-Fi, family, Siri-setup, or
paired-accessory data. The next beats are the Action Button's **Shortcut**
panel and a generic Shortcuts grid. Each one names and shows only the current
app's shortcut and icon: `Luna`, `Luna Reader`, `Luna Video`, or `Luna
Price Tracker`. The checked-in clips are generated by
`scripts/generate_action_button_guides.swift`; named light/dark resources are
selected per surface, while `ActionButtonGuide.mp4` is the current Luna fallback.

`SetupGuideVideo` owns a second stop condition for the Action Button guide:
both `willEnterForeground` and `didBecomeActive` stop and pause PiP. This makes
the return immediate even if the system rebuilds PiP during activation, and it
leaves `wantsPictureInPicture` false. A fresh **Open Settings** tap is therefore
the only way the guide may resume; merely foregrounding Luna never restarts it.

## Bundled shortcut + user setup

**Each app ships its own signed shortcut, named after the app.** All four live in
`Luna/Resources/` — `Luna.shortcut`, `Luna Reader.shortcut`,
`Luna Video.shortcut`, `Luna Price Tracker.shortcut` — and every app target
excludes the other three through a synchronized-group membership exception, so
exactly one is in any bundle (deleting or renaming one means editing
`project.pbxproj` too, per CLAUDE.md). They cannot be one shared file: a
shortcut's Save / Provide Context actions name a specific app, and a device with
two Luna apps installed would otherwise show two identically named entries in
the Action Button picker. `BundledShortcut.resourceName` switches on
`LunaApp.current` and must keep matching the filenames — iOS names an imported
signed shortcut after the file it came from, which is what
`BundledShortcut.displayName` reports to the setup copy.

Each is an AEA1-signed `.shortcut` bundle. Settings → "Install Shortcut"
(`BundledShortcut.presentInstaller`) shares the bundled file to the Shortcuts
app (`shortcuts://import-workflow?url=` REJECTS local file URLs, so install
stays share-sheet based).

> **Manual step (signed file, cannot be generated by this codebase): the
> bundled shortcut must be re-authored by hand** in the Shortcuts app to the
> new shape — Get Current App + on-screen URL extraction → Provide
> Context(CurrentApp, OnScreenURLs), then branch on `result.Outcome`: for
> Screenshot, Take Screenshot and call Save(CurrentApp, screenshot,
> result.Metadata); for Download, call Save(CurrentApp, no screenshot,
> result.Metadata); for Done or Unhandled, stop (using `result.Media` only on
> Done) — exported once per app, renamed to that app's name
> (`Luna Reader.shortcut`, …), and dropped into `Luna/Resources/`. This is a
> **clean break**: old installs (the Screen Analysis Prompt / Save from App
> chain) reference deleted intents and must be reinstalled via Settings →
> Install Shortcut.

User setup:
1. Enable the Safari extension (see `safari-extension.md`) — feeds
   `SafariURLStore` for the no-screenshot Safari save.
2. Settings → Install Shortcut → share to Shortcuts → Add Shortcut. First run
   prompts to allow sharing app info with Luna; choose Always Allow.
3. Settings → Action Button → Shortcut → pick the app's own shortcut ("Luna",
   "Luna Reader", "Luna Video" or "Luna Price Tracker").

Settings' Action Button shortcut sections (the install rows, On-Screen URLs, Double
Save) are hidden unless `ShortcutSettingsScreen.deviceHasShortcutSetup` — iOS 27 AND
known Action Button hardware, asked of the same `OnboardingSaveSetupMode` the
onboarding lesson asks, so the two never disagree. The Safari extension is NOT part
of that gate and stays on every OS. The onboarding
Messages lesson also requires known Action Button hardware; otherwise it teaches
the ordinary two-tap share/action-extension route and verifies it with a separate
App-Group marker (see `reader-onboarding.md`). Action Button can't be assigned
programmatically; the simulator therefore exercises the share-sheet fallback
(test the intent itself by running the shortcut from the Shortcuts app).
On-device QA still owed: real
Action Button run on an iOS 27 device (FM vision/PCC can't run in CI sims),
digest threshold tuning, and the fuzzy Safari title→search save across sites.

The Live Activity widget's Suspend/Resume intents
(`LunaMediaDownload.LiveMediaDownloadManager`) are a separate flow, untouched
by the capture intents.

> **ITMS-90626**: an App Intent `title`/`description`/parameter string must NEVER
> contain "apple" or Siri references, or App Store processing silently drops the
> build. (Doc comments, `.apple` enum cases, and `itunes.apple.com` URLs in code
> are fine — only the AppIntents metadata strings are scanned.)
