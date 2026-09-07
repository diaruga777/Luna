# Plan: audio transcription through the plugin platform (central Luna)

Status: LANDED on main 2026-09-07 (packages A–D). Reference doc:
`claudedocs/transcription.md`. Deviations from this plan are recorded there
and in the package commits.

## 0. Summary and locked decisions

A plugin's `article` Model gains a third body source beside `html` and
`document`: **`transcription`**, an audio or video file Luna downloads,
transcribes on device, and turns into an ordinary reader article. The
file is deleted once the transcript is written. Text stays what it is
(an `article` Model with `html`); a video that should be KEPT stays a
`media` Model. So the three things a plugin can hand back for reading
are: text, a file to transcribe, or (unchanged) a media asset to store.

Locked decisions, each with the reason:

1. **The transcript is an `article` Model, not a fourth kind.** Reader
   articles are what the user asked for, and every reader surface
   (scroll, RSVP, read-aloud, export, Kindle/Xteink, Spotlight) already
   hangs off `Outcome.article`. `produces: ["article"]` needs no new
   adopter registry and no new `LunaApp.includes` case.
2. **Transcription is deferred, never inside the ingest walk.** The
   walk has a 30 s idle watchdog and runs in extensions. A
   `transcription` Model parks the save (`state == .pending`) with a
   job row; the central app's `TranscriptionJobRunner` downloads,
   transcribes, and persists later. Mirrors `.needsArchive` parking.
3. **A parked transcription is owned by its job row, not by the launch
   sweep.** `SavesIngestor.ingestAllPending` re-ingests every `.pending`
   and `.failed` save at launch (`SavesIngestor.swift` ~L509). A
   re-walk of a transcribing save would create a second job, and a
   re-walk of a FAILED one would run without the original intent and
   turn the article attempt into a media save. The sweep therefore
   SKIPS any save that has a `transcriptions` row; the runner owns
   those retries.
4. **Per-video choice is an ingest INTENT, not a plugin setting.**
   `IngestInput.intent: IngestIntent?` (`.transcribe`) is forwarded to
   `classify`/`ingest` as `intent?: "transcribe"`. The seven media
   plugins decline when it is set; the transcript plugins sit at a
   LOWER priority and claim whether or not it is set. Default save →
   downloader wins. Transcribe action → downloader declines →
   transcript plugin claims. Downloader plugin disabled in Settings →
   Plugins → transcript plugin is the platform's default. Nothing is
   read from settings inside `classify` (§3.1 of plugins.md forbids
   it).
5. **A transcribe intent no plugin served is a failure, never a
   download.** When `intent == .transcribe` and the plugin stage
   `.passed`, the pipeline returns `.failed(.noTranscriptSource)`
   instead of running the Swift classifier. Otherwise "Transcribe" on a
   TikTok link with the transcript plugin disabled would silently
   download the video.
6. **Download first, then transcribe; prefer the cheapest source.**
   The plugin chooses in this order: captions from the source (an
   `html` Model, no file at all), an audio-only file, a video file.
   The Swift side never inspects the video; `AVAssetReader` reads the
   audio track straight from the container. A `video` spec may carry
   `audioURL` (Reddit) and then ONLY the audio leg is fetched.
7. **Engine: `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26), on
   device.** Already proven in `LunaWriterVoice`. Below iOS 26 the
   job fails terminally with `.transcriptionFailed` copy naming iOS 26;
   the in-app Transcribe affordances are hidden there. WhisperKit is
   out of scope.
8. **Transcribed files are deleted** on success, on terminal failure,
   and by a launch sweep of the scratch directory for any file whose
   job row is not `downloading`/`transcribing`.
9. **Central Luna only.** `LunaApp.transcribesMedia` is true for
   `.luna` alone. Sibling apps never see `Outcome.transcription`
   (their plugin stage is nil); if one ever did, `owningApp` is
   `.reader` and the gate drops it like any foreign kind.
10. **Transcript plugins are separate bundled files** (`<platform>-
    transcript.js`, ids `app.luna.<platform>.transcript`). Duplicated
    URL/ladder code between a media plugin and its transcript variant
    is accepted; the JS test suites pin both against the same fixtures.
11. **Wiring is protocol contracts, never stored closures** (owner
    standard). New seams below are `*Providing`/`*Leasing`/
    `*Reresolving` protocols with strong references, installed by
    `PluginPlatformComposition.install()` or `KindWiring+Luna`.

## 1. Behaviour

- **Save a YouTube link normally** → `youtube.js` claims → media save,
  as today.
- **Long-press the paste row → "Paste & Transcribe"**, or long-press a
  media card → **"Transcribe"** (central Luna, iOS 26+) → a NEW pending
  save for the URL with `intent: .transcribe` → `youtube.js` declines →
  `youtube-transcript.js` claims `article` → captions if present
  (article ready within the walk), else `transcription: {audio}` or
  `{video}` → the save parks; the card says "Transcribing…" → the
  runner finishes → an ordinary reader article.
- **Disable YouTube (media) in Settings → Plugins** → every YouTube
  save transcribes by default, from every surface including Safari and
  the share sheet (the extension parks the row; the app finishes it).
- **Failure** → the save turns `.failed` with a reason under the title,
  no URL Rescue offered for transcription reasons (`isRescuable` false).
- Nothing changes for Reader, Downloader, Price Tracker, or Writer.

## 2. Models (LunaModels)

### 2.1 `ArticleTranscriptionSpec` (`Plugin/PluginModel.swift`)

```ts
interface ArticleTranscriptionSpec {
  url: string;                       // the file to fetch
  type: "audio" | "video";
  audioURL?: string;                 // a separate audio leg for a video; when present ONLY this is fetched
  headers?: Record<string, string>;  // filtered to PluginModelCaps.allowedHeaderNames like MediaAssetSpec
  expiresAt?: number;                // epoch seconds; stale → re-resolve before fetching
}
```

Hand-decoded like `ArticleDocumentSpec`: `url` required via
`requiredPluginURL`, `type` via a `TranscriptionType` raw enum
(`unknownKind` on anything else), headers via `pluginHeaders`, expiry
via the same optional-epoch decode `MediaModel.expiresAt` uses.

### 2.2 `ArticleModel` decode rule change

- `html` becomes OPTIONAL when `transcription` is present. Absent
  `transcription` keeps today's `missingField("html")`.
- `document` and `transcription` together → new
  `PluginModelValidationError.conflictingFields("document",
  "transcription")`.
- Precedence in the adopter: `document` > `transcription` > `html`.
  When `transcription` is present AND `html` is non-empty, the html is
  converted as trusted and its blocks PRECEDE the transcript (a video
  description or post text). `leadImageURL` behaves as today.

### 2.3 `TranscriptionRequest` (new file `TranscriptionRequest.swift`)

Codable, Equatable, Sendable value the pipeline carries and the store
persists:

```swift
public struct TranscriptionRequest {
    public enum MediaKind: String { case audio, video }
    public let mediaURL: URL
    public let mediaKind: MediaKind
    public let audioURL: URL?
    public let requestHeaders: [String: String]
    public let expiresAt: Date?
    public let language: String?        // ArticleModel.language, BCP-47
    public let title: String
    public let author: String?
    public let pluginID: String
    public let leadContent: ArticleContent?   // converted html, if any
}
```

### 2.4 `PluginAdoptedOutcome.transcription(TranscriptionRequest)`

New case. `PluginOutcomeMapping.outcome` maps it to
`Outcome.transcription(TranscriptionRequest)`.

### 2.5 `SaveFailureReason`

Two new cases, both `isRescuable == false`, both excluded from any
"retry on launch" list the same way `.notContent` is:

- `.noTranscriptSource` — "Nothing here could be transcribed."
- `.transcriptionFailed(String)` — detail is user-facing copy already
  localised by the runner (iOS 26 requirement, no on-device model for
  the language, no audio track, file too large, engine error).

Strings: `SaveFailure_noTranscriptSource_Luna`,
`SaveFailure_transcriptionFailed_Luna` (takes `%@`), plus the detail
strings listed in §5.5. Follow `claudedocs/strings.md` (descriptive
key, `_Luna` suffix, `L10n.string`, never interpolate a key).

### 2.6 `LunaApp.transcribesMedia`

`public var transcribesMedia: Bool { self == .luna }` beside
`sharesByEmail`, with a doc comment naming this plan.

### 2.7 Seams (bottom of stack, like `PluginMediaSeams`)

```swift
public protocol TranscriptionReresolving: AnyObject {
    /// Re-runs `pluginID`'s ingest with reason "reresolve" and returns the
    /// fresh request, an html-only article (captions appeared), or nil.
    func reresolve(sourceURL: URL, pluginID: String, saveID: UUID) async -> TranscriptionReresolution?
}
public enum TranscriptionReresolution { case request(TranscriptionRequest), article(ArticleContent) }
public enum PluginTranscriptionSeams { public static var reresolver: (any TranscriptionReresolving)? }

public protocol PendingSaveStatusProviding: AnyObject {
    func status(forSaveID id: UUID) -> String?
}
public enum PendingSaveStatus { public static var provider: (any PendingSaveStatusProviding)? }
```

## 3. Pipeline (LunaIngest, LunaPluginIngest, LunaSaves, LunaShareSurface)

### 3.1 `IngestInput.intent`

`public enum IngestIntent: String, Sendable { case transcribe }`;
`IngestInput.intent: IngestIntent?` defaulting nil, threaded through
every initialiser. `SavesIngestor.ingest(_:forceArticle:page:
allowsInteractivePrompt:)` gains `intent: IngestIntent? = nil` and
passes it into `IngestInput`.

### 3.2 Hook payloads (LunaPluginIngest `PluginHookPayloads.swift`)

`PluginClassifyInput.intent: String?` and `PluginIngestHookInput
.intent: String?`, encoded ONLY when non-nil (`encodeIfPresent`), so
existing plugins and the Safari host see no new key. `PluginIngestStage`
and `PluginMediaResolver` fill it from `IngestInput.intent?.rawValue`
(the media resolver passes nil — it never transcribes).

### 3.3 `PluginIngestStage`

- The intent rule (decision 5) lives in `IngestPipeline.runUnbounded`,
  right where `.passed` falls through to `Classifier.classify`: if
  `input.intent == .transcribe` return `.failed(.noTranscriptSource)`
  and record a `SaveDiagnostics` line under `plugin`.
- `adopt`: no change beyond the new `PluginAdoptedOutcome` case flowing
  through `PluginOutcomeMapping`.

### 3.4 `Outcome.transcription(TranscriptionRequest)` (LunaIngest)

- `owningApp` → `.reader`.
- Every exhaustive `switch` on `Outcome` gets the case. Known sites:
  `IngestorOutcomePresenter.present` (LunaSaves), `ShareSurfaceDriver`
  (LunaShareSurface, both the persist switch and any result-screen
  switch), `IngestPipeline` internal switches, `LinkImportRunner`,
  `SurfaceSupport`, `RecentURLMatcher` (Luna/UtilCard),
  `IntentIngestHelper` (LunaIntents) if it switches, `PluginModelDrain`
  (Luna/). Let the compiler find the rest; do not add `default:`.
- Presenter behaviour: `IngestorOutcomePresenter` →
  `ingestor.parkTranscription(request, for: item)`. Share/action
  driver: same park, then the SAME confirmation the `.needsArchive`
  park shows (the save exists; the app finishes it). App Intents: the
  save reports as saved.

### 3.5 `SavesIngestor.parkTranscription`

```swift
fileprivate func parkTranscription(_ request: TranscriptionRequest, for item: SavedItem) async {
    store.setTitle(item.id, request.title)          // whatever the existing title-setter is
    TranscriptionJobStore.shared.enqueue(saveID: item.id, request: request)  // status "queued"
    SaveDiagnostics.record("transcription queued by plugin \(request.pluginID) (\(request.mediaKind))", category: "transcription")
}
```

The save stays `.pending`. `ingestAllPending` skips items for which
`TranscriptionJobStore.shared.hasJob(saveID:)` is true (decision 3).
`SavesIngestor.ingest` itself must ALSO refuse to re-walk such an item
(return `.supported` early) so no other caller can double-run it;
deleting the save cascades the row and the guard disappears with it.

### 3.6 `ArticleModelAdopter` (LunaReaderUI)

After the `document` branch: if `model.transcription` is present,
convert `model.html` (when non-empty) as trusted for `leadContent`,
build `TranscriptionRequest` (headers are already the filtered set;
`language` from the Model), and return `.transcription(request)`. No
network here. Nothing OS-gated here either — the extension may run on
any iOS; the runner decides.

## 4. Storage (LunaStorage)

### 4.1 Schema 14

```sql
CREATE TABLE IF NOT EXISTS transcriptions (
    save_id        TEXT PRIMARY KEY NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
    status         TEXT NOT NULL,        -- queued | downloading | transcribing | done | failed  (raw, NO CHECK)
    request_json   TEXT NOT NULL,        -- TranscriptionRequest, Codable
    attempts       INTEGER NOT NULL DEFAULT 0,
    failure        TEXT,                 -- last failure, diagnostic text
    scratch_path   TEXT,                 -- relative path under Transcriptions/ while a file exists
    created_at     REAL NOT NULL,
    updated_at     REAL NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS transcriptions_status ON transcriptions(status);
```

`SavesDatabase.schemaVersion = 14`. `CREATE TABLE IF NOT EXISTS` in
`tables` covers both fresh and existing databases (no ALTER needed).
An unknown `status` raw value maps to `.failed` in Swift, per the
no-CHECK rule. Extend `SavesSchemaPluginColumnsTests`' sibling to pin
the table and cascade.

### 4.2 `TranscriptionJobStore` (`LunaStorage/TranscriptionJobStore.swift`)

Same shape as `PendingPluginModelStore`: `shared`, `init(saves:)`,
all access through `saves.write`/`pluginSidecar`. API: `enqueue`,
`hasJob(saveID:)`, `job(saveID:)`, `nextRunnable()` (oldest
`queued`, or `downloading`/`transcribing` left by a killed process),
`setStatus(_:saveID:scratchPath:)`, `recordFailure(saveID:detail:
terminal:)` (increments `attempts`; terminal writes `failed`),
`markDone(saveID:)`, `liveScratchPaths()` for the sweep, `status(saveID:)`.
Every write posts `.savesChanged` so the pending card refreshes.

### 4.3 Scratch directory

`<AppGroup>/Transcriptions/<save-id>.<ext>`; ext from the URL path or
`media` when unknown. Not owned by `files`/`file_refs` (it is never a
save's artifact); the runner unlinks it, and `TranscriptionScratchSweep
.run()` at launch unlinks every file whose save has no
`downloading`/`transcribing` row.

## 5. `LunaTranscribe` (new SwiftPM target)

`dependencies: ["LunaModels", "LunaStorage", "LunaAppConfig",
"LunaSaves"]`. Frameworks: AVFoundation, Speech. No UIKit. Linked
into `Luna` and `LunaTests` only (`scripts/add_transcribe_links.rb`,
modelled on `add_price_compare_links.rb`; the xcodeproj gem is
installed — if `proj.save` crashes, hand-edit `project.pbxproj` the way
the Vault work did).

### 5.1 `TranscriptionEngine`

```swift
public struct TranscriptSegment: Equatable { public let start: TimeInterval; public let end: TimeInterval; public let text: String }
public protocol TranscriptionEngine {
    var availability: TranscriptionAvailability { get }
    func transcribe(audioFileURL: URL, mediaKind: TranscriptionRequest.MediaKind, language: String?, progress: (Double) -> Void) async throws -> [TranscriptSegment]
}
public enum TranscriptionAvailability { case available, unsupportedOS, unsupportedLanguage, modelNotInstalled }
```

`SpeechAnalyzerFileTranscriber` (`@available(iOS 26, *)`):

1. Locale: `Locale(identifier: language)` when given, else `.current`.
   Match against `SpeechTranscriber.supportedLocales` by
   `language.languageCode` (region-insensitive). No match →
   `.unsupportedLanguage` (terminal).
2. Assets: `AssetInventory.status(forModules:)`; if `.supported`, call
   `AssetInventory.reserve(locale:)` when the locale is not in
   `reservedLocales` and the count is below `maximumReservedLocales`,
   then `assetInstallationRequest(supporting:)?.downloadAndInstall()`.
   Still not installed → `.modelNotInstalled` (terminal for this
   attempt; the runner treats it as retryable once, then terminal).
3. Module: `SpeechTranscriber(locale:, transcriptionOptions: [],
   reportingOptions: [], attributeOptions: [.audioTimeRange])`.
4. Audio: `AudioTrackReader` decodes the FIRST audio track with
   `AVAssetReader` + `AVAssetReaderTrackOutput` into PCM buffers in
   `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])`
   (convert with `AVAudioConverter` when the reader's native format
   differs), yielding `AnalyzerInput(buffer:, bufferStartTime:)` on an
   `AsyncStream`. No audio track → `noAudioTrack` (terminal).
5. Run `analyzer.analyzeSequence(stream)` concurrently with draining
   `module.results` (subscribe BEFORE start, as `LunaWriterVoice` does),
   then `finalizeAndFinishThroughEndOfInput()`. Final results only;
   each `Result.range` gives the segment's `start`/`end`.
6. Progress: fraction of decoded duration over asset duration.

### 5.2 `TranscriptArticleBuilder`

Pure. `make(segments:, request:) -> ArticleContent`:
`title = request.title`, `author = request.author`, blocks = `request
.leadContent?.blocks` followed by paragraphs. Paragraph rule: start a
new paragraph at a silence gap ≥ 2.0 s between segments, or when the
current paragraph exceeds 90 words and the segment ends a sentence
(`.`, `?`, `!`). Trim, collapse whitespace, drop empty segments. Empty
transcript (no words) → the builder throws `TranscriptionError
.noSpeech`, terminal, copy "No speech was found in this recording."

### 5.3 `TranscriptionSourceDownloader`

`URLSession` download task (delegate-based, foreground) with the
request headers. Ceiling `maxBytes = 2 GiB` on `expectedContentLength`
and on bytes received → `tooLarge` (terminal). Picks `request.audioURL
?? request.mediaURL`. Before fetching, if `expiresAt` is in the past,
or the response is 401/403/410, ask `PluginTranscriptionSeams
.reresolver` ONCE; `.request` replaces the stored request (row
rewritten) and the fetch retries; `.article` short-circuits to
persisting that content; nil → retryable failure. Temp file → moved to
the scratch path; `scratch_path` written BEFORE the download starts
so a kill leaves a sweepable name.

### 5.4 `TranscriptionJobRunner` (`@MainActor`, `shared`)

- `kick()` is idempotent: no-op while a job runs; otherwise takes
  `nextRunnable()` and runs it off-main inside a background lease
  (`TranscriptionBackgroundLeasing` protocol, installed by the app
  shell over `UIApplication.beginBackgroundTask`; nil lease → run
  without one, as tests do). After each job, `kick()` again until the
  queue is empty.
- Job: `downloading` → fetch → `transcribing` → engine → builder →
  `IngestorKindHandlers.article?.persistArticle(content, html: "", for:
  item, url:, store:)` (the same path a plugin `html` article takes, so
  images, readiness observers, Spotlight and Kindle auto-send all
  happen) → `markDone` → unlink scratch. `persistArticle` is the ONLY
  way the save leaves `.pending`.
- The save row must still exist and still be `.pending` at persist
  time; if it was deleted meanwhile, unlink and stop.
- Failure policy: transient (network, HTTP 5xx/429, re-resolve nil,
  `modelNotInstalled` first time) → `recordFailure(terminal: false)`,
  stays `queued`, retried by the next `kick()` with backoff
  `min(2^attempts, 60) * 60 s` from `updated_at`, up to 3 attempts, then
  terminal. Terminal (`unsupportedOS`, `unsupportedLanguage`,
  `noAudioTrack`, `noSpeech`, `tooLarge`, decode/export error, attempts
  exhausted) → `recordFailure(terminal: true)`, `store.markFailed
  (saveID)`, `SaveFailureStore.shared.recordFailure(saveID, reason:
  .transcriptionFailed(detail))`, unlink scratch. The row STAYS (status
  `failed`) so the launch sweep keeps skipping the save; deleting the
  save cascades it.
- Availability check first: `engine.availability == .unsupportedOS` →
  terminal before any download.
- Every step records `SaveDiagnostics` under category `transcription`.

### 5.5 User-facing detail strings (`Transcription_*_Luna`)

`Transcription_needsIOS26`, `Transcription_languageUnsupported`,
`Transcription_modelUnavailable`, `Transcription_noAudioTrack`,
`Transcription_noSpeech`, `Transcription_fileTooLarge`,
`Transcription_failed`; card status `Transcription_statusQueued`
("Waiting to transcribe…"), `Transcription_statusDownloading`
("Downloading audio…"), `Transcription_statusTranscribing`
("Transcribing…"). Menu copy `Transcribe_pasteAndTranscribe`
("Paste & Transcribe"), `Transcribe_cardAction` ("Transcribe").

## 6. App wiring (central Luna; files compiled by `Luna` only)

- `PluginPlatformComposition.install()` also installs
  `PluginTranscriptionSeams.reresolver = PluginTranscriptionReresolver
  (invoker:processKind:)` (LunaPluginIngest) — the same walk
  `PluginMediaResolver.reresolve` does, but reading the `article`
  Model through `PluginModelAdopters.article` and returning
  `.request`/`.article`. Add its write to the `KindCompositionRootTests`
  allow-list exactly as `PluginMediaSeams` is.
- `KindWiring+Luna.installFullPluginComposition()` installs
  `TranscriptionJobRunner.shared.lease = AppBackgroundLease()` and
  `PendingSaveStatus.provider = TranscriptionPendingStatusProvider()`
  (reads `TranscriptionJobStore.status` → the §5.5 strings).
- `appDidLaunch`: `TranscriptionScratchSweep.run()` then `runner.kick()`.
  `sceneDidForeground` and `savesDidChange`: `runner.kick()`.
  All three guarded by `LunaApp.current.transcribesMedia` and
  `#available(iOS 26, *)`; below iOS 26 `kick()` still runs so queued
  rows fail terminally with the iOS 26 copy instead of sitting
  `.pending` forever.
- `PendingSaveCardContentViewController`: on `viewDidLoad` and on
  `.savesChanged`, ask `PendingSaveStatus.provider?.status(forSaveID:)`
  and show it instead of "Loading…" when non-nil (`KindDeckProvider`
  must pass the item id in; today it constructs the card with none).
- **Paste row**: `OnboardingPasteRow` gets a `UIContextMenuInteraction`
  (long-press) with one action, "Paste & Transcribe", shown only when
  `LunaApp.current.transcribesMedia` and iOS 26. It reads the
  pasteboard URL through the existing paste path and calls the util
  card's save with `intent: .transcribe`. The save uses
  `store.add(urlString:source:)` (a plain insert; NOT
  `reserveSaveAttempt`, which dedupes onto an existing row) followed by
  `SavesIngestor.shared.ingest(item, intent: .transcribe)`.
- **Media card** (`CardKindPresenting.menuActions` for the media kind,
  same gate): "Transcribe" → the same add + ingest with intent. The
  media save is untouched.

## 7. Plugins (`LunaBundledPlugins/Plugins/`)

### 7.1 Media plugins (7 files)

`classify` receives `input` and returns `false` when `input.intent ===
"transcribe"`. One line each; behaviour otherwise identical (the JS
parity suites must stay green).

### 7.2 Transcript plugins (7 new files), `produces: ["article"]`, `priority: 90`

Common rules:
- `classify` mirrors the media twin's URL family but claims `{ kind:
  "article", itemId }`.
- `ingest` order: captions → audio-only → video. Each step that is
  unavailable or whose fetch fails falls to the next; nothing usable →
  `null`.
- Captions → `{ kind: "article", title, author, language, html }`
  where html is `<p>` per caption paragraph using the SAME paragraph
  rule as §5.2 (gap ≥ 2 s or 90 words at sentence end) so a captioned
  and a transcribed video read alike. Strip `<...>` tags and HTML
  entities from cue text; drop cues that duplicate the previous cue
  (rolling captions).
- File → `{ kind: "article", title, author, language, html:
  <post/description text or "">, transcription: { url, type,
  audioURL?, headers?, expiresAt? } }`.
- Title falls back to `"<Platform> <itemId>"` when the source has none.

Per platform:

| Plugin | Captions | Audio-only | Video | Notes |
| --- | --- | --- | --- | --- |
| `youtube-transcript.js` | `captions.playerCaptionsTracklistRenderer.captionTracks[]`: prefer `kind !== "asr"` in `videoDetails`/audio-track default language, then any non-asr, then asr; fetch `baseUrl + "&fmt=json3"`, parse `events[].segs[].utf8` with `tStartMs`/`dDurationMs` | `streamingData.adaptiveFormats[]` with `mimeType` starting `audio/mp4` and a plain `url` (skip `signatureCipher`); highest `bitrate` | the media plugin's `assetFrom` progressive pick | same ANDROID_VR ladder as `youtube.js`; `expiresAt` from the URL's `expire`; title/author from `videoDetails` |
| `reddit-transcript.js` | none | `secure_media.reddit_video` with `has_audio` → sibling `audio` URL (the media twin's `audioURL`) as `type: "audio"` | `fallback_url` when `has_audio` is false → `null` (silent video has nothing to transcribe) | title from the listing; html = `selftext_html` if any |
| `x-transcript.js` | none | none | best mp4 variant | html = the post text |
| `tiktok-transcript.js` | `video.subtitleInfos[]`: prefer `Source === "ASR"` over `"MT"`, language matching the item's; fetch `Url`, parse WebVTT cues | none | `playAddr`/`downloadAddr` with the media twin's headers | html = `desc` |
| `instagram-transcript.js` | none | an `audio/mp4` representation in `video_dash_manifest` when the data path the twin already reads exposes one (verify against fixtures; skip otherwise) | `video_url` | html = caption text |
| `facebook-transcript.js` | none | none | hd then sd URL | html = description when present |
| `direct-media-transcript.js` | none | audio extension → `type: "audio"` | video extension → `type: "video"` | image/gif → `false`; title = file name |

`README.md` in that folder lists the new files and the intent rule.

## 8. Docs and typings

- `tools/plugin-sim/luna-plugin.d.ts`: `ClassifyInput.intent?`,
  `IngestInput.intent?`, `ArticleTranscriptionSpec`, `ArticleModel.html?`
  + `transcription?`.
- `docs/plugins/api.md` Models + hook sections; `docs/plugins/README.md`
  gets a short "Transcription" walkthrough with `direct-media-
  transcript.js` as the worked example.
- `claudedocs/plugins.md`: §3.1/§3.2 input shapes, §4 Models, §6 walk
  (the intent rule), new §"Transcription" pointing at
  `claudedocs/transcription.md`.
- New `claudedocs/transcription.md`: the whole feature as built.
- `CLAUDE.md`: one paragraph under "Plugins" naming the module, the
  intent, the sweep exemption, and the doc.
- `LunaSafari/Resources/plugin_host.js`: no behaviour change; a comment
  that Safari never sets `intent`.

## 9. Tests (all in `LunaTests`, behaviour-asserting)

- `PluginModelDecodingTests`: spec decode (type enum, header filter,
  epoch expiry), `html` optional with `transcription`, missing html
  without it still fails, document+transcription conflict.
- `PluginIngestStageTests`: intent encoded only when set (fixture plugin
  echoes its input); media-style fixture plugin declines on intent;
  adopter `.transcription` → `Outcome.transcription`; intent + `.passed`
  → `.failed(.noTranscriptSource)`; no intent + `.passed` → Swift floor.
- `PluginModelAdopterTests`: html precedes transcript as `leadContent`;
  request fields; document wins over transcription.
- `TranscriptionJobStoreTests`: enqueue/next/status/failure/done,
  cascade on save delete, unknown status → failed, backoff eligibility.
- `TranscriptionJobRunnerTests` with stub downloader/engine/lease:
  success persists via `IngestorKindHandlers.article`, unlinks scratch,
  row done; transient failure retries then terminal after 3; terminal
  marks failed with reason; 403 → one re-resolve → success; expired
  request re-resolves before fetching; re-resolve returning `.article`
  persists without a download; save deleted mid-job → nothing written;
  `ingestAllPending` skips a save with a job row (drive the real sweep).
- `TranscriptArticleBuilderTests`: paragraph rules, lead content order,
  empty → `noSpeech`.
- `AudioTrackReaderTests`: an `AVAssetWriter`-generated 3 s m4a and a
  video-with-audio mp4 (written at test time into the scratchpad) decode
  to the expected duration/buffer format; a video-only mp4 →
  `noAudioTrack`.
- `SpeechAnalyzerFileTranscriberTests`: `XCTSkipUnless
  (ProcessInfo["RUN_SPEECH_TRANSCRIBER_TESTS"] == "1")`, like the audio
  engine gate; transcribes a bundled 3 s spoken clip.
- `<Platform>TranscriptPluginTests` (7): captions path (new fixtures
  authored from the documented response shapes: `youtube/player-
  captions.json` + `youtube/timedtext.json3`, `tiktok/rehydration-
  subtitles.html` + `tiktok/subtitles.vtt`), audio path (`youtube/
  player-adaptive-audio.json`, reddit `video-with-audio.json`), video
  fallback, decline on nothing, and — for each MEDIA twin — "declines
  when intent is transcribe".
- `PendingSaveCardContentViewControllerTests`: shows the provider's
  status; falls back to Loading… when nil.
- `SavesSchemaTests` sibling: schema 14 table + cascade.
- `LocalizableStringsTests`, `KindCompositionRootTests`,
  `StageRegistryTests` stay green.

## 10. Work packages, order, gates

Each package: its own worktree off CURRENT `main` (`git fetch` and
reset first — agent worktrees have started hundreds of commits stale),
small commits, `xcodebuild build-for-testing -scheme Luna -destination
'generic/platform=iOS Simulator' DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`
in the FOREGROUND (600 s timeout, never backgrounded) before every
commit, `scripts/run_tests.sh --changed` while iterating. A package is
done when its own tests pass and the whole-scheme build is clean;
the lead merges into `main` (in a scratch worktree, then fast-forwards
the main checkout) and runs the full suite once at the end.

| WP | Scope | Depends on |
| --- | --- | --- |
| **A. Contract** | §2 (models, spec, request, outcome case, failure reasons, `transcribesMedia`, seams, strings), §3 (intent plumbing, `Outcome.transcription` through every switch, `parkTranscription`, sweep exemption), §3.6 adopter, §4 (schema 14, job store, scratch sweep helper), the `LunaTranscribe` target skeleton with `TranscriptionEngine`/`TranscriptSegment`/`TranscriptArticleBuilder` and the pbxproj link, all §9 tests for those parts. | — |
| **B. Engine + runner** | §5 minus what A did (`SpeechAnalyzerFileTranscriber`, `AudioTrackReader`, downloader, runner, re-resolver, background lease), §6 wiring, pending-card status, paste-row and media-card actions, their tests. | A |
| **C. Plugins** | §7 (7 media declines + 7 transcript plugins), fixtures, the 7 JS suites, `.d.ts`, `docs/plugins/*`, `tools/plugin-sim` still runs each transcript plugin against its fixtures. | A (the decode shape only) |
| **D. Docs** | `claudedocs/transcription.md`, `claudedocs/plugins.md`, `CLAUDE.md`. | B, C |
| **E. Review** | An independent reviewer reads the merged diff against §11, runs the full suite on a fresh simulator, fixes or reports. | A–D |

B and C run in parallel once A has merged.

## 11. Correctness checklist (the reviewer's list)

1. A `.pending` save with a `transcriptions` row is never re-ingested
   by `ingestAllPending`, by `SavesIngestor.ingest`, or by a pull-to-
   refresh; deleting the save removes the row (cascade) and the scratch
   file (sweep).
2. No code path runs two jobs for one save (runner is single-flight;
   `nextRunnable` never returns a row another task holds).
3. Every scratch file is unlinked on success, on terminal failure, and
   by the launch sweep. No file under `Transcriptions/` survives a job
   that is `done` or `failed`.
4. `persistArticle` is the only transition out of `.pending`; a save
   deleted mid-job writes nothing.
5. `intent` is absent from the JSON when nil; Safari and both
   extensions never set it; each media plugin declines only on the
   exact string `"transcribe"`.
6. A transcribe intent that no plugin serves fails with
   `.noTranscriptSource`; it never produces a media save.
7. `SaveFailureReason` new cases are Codable-stable (raw strings
   named), `isRescuable == false`, and excluded from any launch retry.
8. Below iOS 26 the queued row fails terminally with the iOS 26 copy;
   the affordances are hidden; nothing sits `.pending` forever.
9. Sibling apps compile no new UIKit affordance and their `Outcome`
   switches handle the case by parking or dropping, never crashing.
10. All exhaustive `switch`es updated with the real case, no `default:`
    added to dodge the compiler.
11. `LocalizableStringsTests`, `KindCompositionRootTests`,
    `StageRegistryTests`, the seven media parity suites and the full
    suite pass on a fresh simulator with no stray simulators booted.
12. Plugin fixtures for captions were authored from the documented
    shapes named in §7.2 and each parser tolerates a missing field
    (falls through to the next source, never throws out of `ingest`).

## 12. Out of scope (this wave)

A `transcribe: true` flag on a MEDIA asset (keep the video AND get a
transcript); tap-to-seek timestamps in the reader; live captions while
streaming (`MTAudioProcessingTap`); fragmented-MP4 streaming
transcription; WhisperKit; the Reader app accepting video; a Settings
default "Transcribe by default" outside the plugin enable toggle.
