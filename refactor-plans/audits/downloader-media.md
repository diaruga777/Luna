# Audit: Downloader UI + LunaMediaDownload

Scope: `Luna/Downloader/` (2 files), `LunaLibraries/Sources/LunaMediaDownload/` (14
files), `LunaDownloaderClip/` (4 files), `LunaDownloaderLiveActivity/` (2 files).
Read-only audit — no code changed. Every file in scope was read in full; every
"dead code" and "who uses this" claim below is backed by a repo-wide grep (shown
inline), excluding build directories (`.build*`, `build/`) and the stale
secondary worktree at `.claude/worktrees/agent-a44f9578d823e01c8/` (a different
agent's sandbox containing a pre-refactor `SavedMediaGridViewController`/
`SavedMediaViewerViewController` that no longer exist on `main`).

Per CLAUDE.md, `CODE_REVIEW_PLAN.md` and `PERF_REVIEW_PLAN.md` were checked first:
neither plan touched `Luna/Downloader/` or `LunaMediaDownload` specifically (their
"deliberately deferred" lists are both about Reader/store/mail/content-extraction
work), so nothing here is a re-report of prior deferred work. The only globally
deferred items that apply here too are Swift 6 strict concurrency and per-app
dependency slimming (both already documented in CLAUDE.md) — not repeated below.

---

## 1. Structure map

### `Luna/Downloader/`

| File | Responsibility | Public/internal surface | Used by |
|---|---|---|---|
| `SavedMediaCardsViewController.swift` (911 lines) | Downloader's root screen: adapts `SavedMediaItem`s into `CardCarousel` cards, owns store plumbing (cross-process observation, expiry purge, Photos reconciliation, context menu, pasteboard card, download-progress footer). Contains 5 nested types: the VC itself, `PasteboardMediaCardContentViewController`, `UndownloadedMediaCardContentViewController`, `CircularDownloadProgressView`, `EmptyMediaView`. | `internal final class`, instantiated directly (no public init) | `Luna/SceneDelegate.swift:77` (`case .downloader: root = SavedMediaCardsViewController()`) — the only construction site. |
| `PhotosReferenceBadgeView.swift` (44 lines) | Compact code-drawn Photos-rosette badge shown on cards backed by a Photos asset. | `internal final class`, no public init | Only `SavedMediaCardsViewController.swift:510` (`topLeadingAccessoryForCardAt`). |

### `LunaLibraries/Sources/LunaMediaDownload/`

| File | Responsibility | Public API surface | Used by (repo-wide) |
|---|---|---|---|
| `LiveMediaDownloadManager.swift` (1462) | The durable, cross-process, URLSession-background-task-backed download engine: resolve → download → (mux for Reddit) → save → Live-Activity lifecycle. Owns `JobStore` (persisted `jobs.json`) and the `LiveMediaDownloadJob` model. | `LiveMediaDownloadManager.shared` (singleton), `LiveMediaDownloadOwnership`, `LiveMediaDownloadStartPolicy`, `WiFiOnlyDownloadGate`, `DownloaderJobPhase`, `DownloaderJobSnapshot`, `.downloaderJobProgressChanged` notification | `Luna/AppDelegate.swift`, `SceneDelegate.swift`, `SavedMediaCardsViewController.swift`, `MediaAutoDownloader.swift`, `LunaDownloaderLiveActivityWidget.swift` (suspend/resume intents), Settings screens, App Intents (26 files total reference the type). |
| `SavedMediaStore.swift` (780) | The Downloader's durable manifest (`savedMedia.json`): `SavedMediaItem` model (undownloaded/localFile/photosReference tri-state), CRUD, dedup-by-platform-id, retention purge, cross-process Darwin-notification bridge, stat-token read cache. | `SavedMediaStore.shared`, `SavedMediaItem`, `MediaRetentionOption`, `MediaRetentionSettings`, `.savedMediaChanged` | 23 files: `SavedMediaCardsViewController`, `LiveMediaDownloadManager`, `MediaAutoDownloader`, `MediaDownloadService`, `LunaShareSurface/SavedNonTextualViewController`, Settings, tests. |
| `SocialMediaResolver.swift` (605) | Foreground, keyless per-platform media resolution (X/TikTok/Instagram/Facebook/Reddit) via injectable `fetch`; hosts the pure, fixture-testable HTML/JSON parsers (`XMediaParser`, `TikTokMediaParser`, `InstagramMediaParser`, `FacebookMediaParser`, `RedditMediaParser`) and `MediaDownloadHTTP` UA constants. | `SocialMediaResolver`, `SocialMediaResolving` protocol, the 5 parser enums, `MediaDownloadHTTP` | `MediaDownloadService` (default resolver), `LiveMediaDownloadManager` (reuses `facebookVideoPluginURL`, `MediaDownloadHTTP`, `RedditMediaParser.audioURL(fromDASHManifest:)`), `LunaTests/SocialMediaResolverTests`, `RedditMediaParserTests`. |
| `MediaAutoDownloader.swift` (233) | The ingest-funnel hook: decides whether/how a just-saved platform post auto-downloads (Downloader → app storage; sibling apps → Photos), App-Intent entry points, and Shortcuts export-filename policy (`IntentMediaExportNaming`). Also `isRunningInDownloader` bundle-id sniffing (the cross-module ownership signal). | `MediaAutoDownloader` enum (all static) | `ReadingListIngestor` (ingest funnel), App Intents, `LiveMediaDownloadManager` (`isRunningInDownloader`), `DownloaderInstallationPolicy`. 15 files. |
| `AutoDownloadSettings.swift` (132) | App-Group-backed `UserDefaults` flags: per-platform auto-download toggles, Wi-Fi-only gate + its pending-URL list, dedup "already downloaded" list, clipboard/Photos auto-save toggles. | `AutoDownloadSettings` enum (all static) | 19 files — Settings screens, `LiveMediaDownloadManager`, `MediaAutoDownloader`, `MediaDownloadService`, tests. |
| `DownloaderInstallationPolicy.swift` (44) | `LunaInstallationMarkers` (App-Group "was this app ever installed" markers, intentionally uninstall-durable) + `DownloaderIntentPhotoPermission` (foreground Photos-permission preflight gate for intents). | `LunaInstallationMarkers`, `DownloaderIntentPhotoPermission` | `Luna/Settings/InstalledAppMarkers.swift`, `MediaAutoDownloader`, App Intents (`ProvideContextIntent`), `SavedMediaCardsViewController` (`DownloaderIntentPhotoPermission.requestIfNeeded()` in `downloadPasteboardURL`). |
| `LiveMediaDownloadActivity.swift` (88) | `LiveMediaDownloadAttributes` (ActivityKit `ActivityAttributes`/`ContentState`, `#if canImport(ActivityKit)`-gated), `MediaAsset.Kind.liveActivityKind`, `LiveMediaDownloadAssets.thumbnailURL`. | Public struct/enum | `LiveMediaDownloadManager`, `LunaDownloaderLiveActivityWidget.swift`, `DownloaderProgressFooterView` (LunaReadingListUI). |
| `MediaDownload.swift` (180) | Shared value types/protocols: `MediaAsset`, `MediaDownloadError`, `MediaDownloadablePlatform`, `SocialMediaResolving`, `PhotoLibrarySaving`, `DownloadedMedia`, `MediaDownloadStorage` (temp-file directory). | Public | Nearly every other file in the module + `LunaShareSurface`, `LunaDownloaderClip`. |
| `MediaDownloadService.swift` (295) | The **foreground** orchestration path (resolve→download→save), used by short-lived processes (action extension, Clip, App Intents): `MediaDownloadService` (implements `MediaDownloading`) + `MediaFileDownloader` (a `URLSessionDownloadDelegate`-backed continuation-based single-file streamer, incl. the Reddit mux sub-path). | `MediaDownloadService`, `MediaDownloading`, `MediaFileDownloader` | `MediaAutoDownloader`, `LunaShareSurface/SavedNonTextualViewController`, `LunaDownloaderClip/ClipDownloadViewController`. 8 files. |
| `MediaItemProvider.swift` (92) | `NSItemProvider` construction for sharing/pasteboard (lazy Photos-resource file representation), `MediaPasteboard.copy`. | `MediaItemProviderBacking`, `MediaItemProviderFactory`, `MediaPasteboard` | `SavedMediaCardsViewController.share(_:sourceIndex:)`, `LiveMediaDownloadManager.copyToClipboardIfEnabled`, `MediaDownloadService.copyToClipboardIfEnabled`. |
| `MediaMuxer.swift` (52) | AVFoundation video+audio-file muxing (no ffmpeg dependency) — the one place Reddit's split video/audio streams get combined. | `MediaMuxer.mux(videoURL:audioURL:outputURL:)` | `LiveMediaDownloadManager.startRedditMuxedDownload`, `MediaDownloadService.MediaFileDownloader.downloadAndMux`. No direct test. |
| `MediaPreviewFetcher.swift` (34) | Downsampled (ImageIO) still-image fetch for a memory-constrained extension preview. | `MediaPreviewFetcher.image(from:maxPixelSize:)` | Only `LunaShareSurface/SavedNonTextualViewController.swift:972`. Not used anywhere in `LunaMediaDownload` itself or Downloader. |
| `PhotoLibrarySaver.swift` (158) | PhotoKit wrapper: add/read authorization, save, fetch, delete, write-resource-to-file. | `PhotoLibrarySaver` (implements `PhotoLibrarySaving`) | 20 files — `LiveMediaDownloadManager`, `MediaDownloadService`, `SavedMediaCardsViewController`, `MediaItemProviderFactory`, `MediaAutoDownloader`, tests. No dedicated `PhotoLibrarySaverTests` file (see §3). |
| `RedditAudioFetcher.swift` (54) | Resolves+downloads a Reddit video's audio companion (fast-path guessed URL, DASH-manifest fallback). Explicitly documented as shared to avoid duplicating between the two download engines. | `RedditAudioFetcher.fetch` | `LiveMediaDownloadManager.startRedditMuxedDownload`, `MediaDownloadService.MediaFileDownloader.downloadAndMux`. |

### `LunaDownloaderClip/` (App Clip target)

| File | Responsibility | Used by |
|---|---|---|
| `AppDelegate.swift` | Purges `MediaDownloadStorage` on scene-connect. | Clip lifecycle only. |
| `SceneDelegate.swift` | Routes launch URL / user activity into the one `ClipDownloadViewController`. | Clip lifecycle only. |
| `ClipLaunchURL.swift` | Parses the Clip's invocation URL into a downloadable source URL (query-param names, `/download#fragment`, or the bare URL itself if it isn't a `luna`-hosted link). | `SceneDelegate.handleLaunchURL` path; **no test file** (see §3). |
| `ClipDownloadViewController.swift` | Standalone UI: download via `MediaDownloadService.downloadFirstMediaToFile`, then share sheet. Fully self-contained; does not touch `SavedMediaStore` or `LiveMediaDownloadManager`. | Sole screen of the Clip target. |

### `LunaDownloaderLiveActivity/` (Widget extension target)

| File | Responsibility | Used by |
|---|---|---|
| `LunaDownloaderLiveActivityBundle.swift` | `@main` `WidgetBundle` entry point. | OS. |
| `LunaDownloaderLiveActivityWidget.swift` | SwiftUI Live Activity/Dynamic Island UI + the two `AppIntent`s (`SuspendLiveMediaDownloadIntent`, `ResumeLiveMediaDownloadIntent`) that are the **only** callers of `LiveMediaDownloadManager.suspend(jobID:)`/`.resume(jobID:)` anywhere in the app (verified: `grep -rn "\.suspend(jobID\|\.resume(jobID"` outside this file returns nothing). | OS-hosted widget; App Intents invoked from the Dynamic Island/Lock Screen UI, not from any Luna screen. |

---

## 2. Findings

### 2.1 Stored-callback communication

This module is unusually clean on this axis — most cross-component signaling goes
through `NotificationCenter` (`.savedMediaChanged`, `.downloaderJobProgressChanged`,
Darwin notifications) rather than stored closures, and the closures that do exist
are one-shot init-time configuration, not persistent bidirectional wiring.

- **`LiveMediaDownloadManager.backgroundCompletionHandler`**
  (`LiveMediaDownloadManager.swift:140`, set at `:321-325`
  `attachBackgroundCompletionHandler`, invoked+cleared at `:1093-1098`
  `urlSessionDidFinishEvents`). This is the OS-mandated single-completion-handler
  contract for `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
  (installed from `Luna/AppDelegate.swift:255`) — not a design smell, just the one
  place this module holds a callback across an async boundary. No delegate
  protocol needed; there is exactly one caller and one callee by construction.
- **Card-content init closures** — one-shot, config-only, matching the "fine"
  carve-out in the task brief:
  - `UndownloadedMediaCardContentViewController(item:download:)` —
    `SavedMediaCardsViewController.swift:440-442` sets it, `:783` invokes it on tap.
  - `PasteboardMediaCardContentViewController(url:download:)` —
    `:430-432` sets it, `:684-686` invokes it on tap.
  - Both are single-purpose "tell the host to start this download" callbacks with
    one setter and one call site; a delegate protocol would be pure ceremony here.
- **`CardContentViewController.audioAvailabilityChanged`** and
  `CarouselCardView.onMuteToggle` are set by `CardCarouselViewController.mount`
  (`LunaDesignSystem`, out of this audit's file list) on every card, including
  Downloader's — noted here only because `SavedMediaCardsViewController` is a
  *consumer* of that contract, not because it stores any closures itself for this
  purpose. No Downloader-owned code participates in that wiring.
- No delegate protocol exists in this module and none is needed — there is no
  cluster of ad hoc closures on any one type that a protocol would consolidate.

### 2.2 View/container boundary violations

**None found — ownership is clean and matches the documented contract.**
`CardCarouselViewController` (LunaDesignSystem) owns playback state, autoplay,
scrubbing, immersion, and chrome uniformly for both hosts, through the
`CardContentViewController` base-class contract (`isPlayable`, `isPlaying`,
`playbackFraction`, `setPlaying`, `seek(toFraction:)`, `setMuted`,
`cardDidBecomeCentered`/`cardDidLeaveCenter` — see
`LunaLibraries/Sources/LunaDesignSystem/CardCarousel/CardContentViewController.swift:14-55`).
`SavedMediaCardsViewController` never touches an `AVPlayer` or scrub fraction
directly; it only *adapts* `SavedMediaItem` into `VideoCardContentViewController` /
`ImageCardContentViewController` / `AnimatedImageCardContentViewController`
instances (all in `LunaDesignSystem`, not audited here since they're shared
infra) and answers `CardCarouselDataSource`/`CardCarouselDelegate` queries. The
one Downloader-specific card content class defined in-scope,
`UndownloadedMediaCardContentViewController`
(`SavedMediaCardsViewController.swift:758-827`), correctly does **not** override
`isPlayable` — it's a static button/progress-ring state, not carousel-driven
playback, so it never fights the carousel's tap/scrub gestures.

The one piece of Downloader-specific "playback-adjacent" state that lives outside
the carousel is legitimate and doesn't reach into carousel internals: per-card
download progress is delivered by `.downloaderJobProgressChanged` directly to
`UndownloadedMediaCardContentViewController`/`PasteboardMediaCardContentViewController`
(`SavedMediaCardsViewController.swift:800-815`, `:715-721,733-741`) — each card
observes the notification itself and filters by its own `sourceURLString`, rather
than the host routing per-card updates. This is exactly the pattern the class doc
comment (`:756-757`) claims, and it keeps `LiveMediaDownloadManager` (a library
module) from needing any carousel-shaped API.

### 2.3 Duplicated or disjoint-but-related logic

#### A. `SavedMediaCardsViewController` vs `ArticleCardsViewController` (Luna/Reader/ArticleCardsViewController.swift)

The task's framing ("recently made to match downloader carousel chrome") is
accurate — the two root-screen hosts now share a near-identical skeleton, wired
independently in each file:

1. **`configureBottomButton` — byte-for-byte identical body**, just called with
   different symbols:
   - Downloader: `SavedMediaCardsViewController.swift:144-151`
   - Reader: `ArticleCardsViewController.swift:372-379`
   ```swift
   private func configureBottomButton(
       _ button: UIButton, symbol: String, action: Selector, accessibilityLabel: String
   ) {
       button.configuration = GlassStyle.circularButtonConfiguration(symbol: symbol, padding: 10)
       button.accessibilityLabel = accessibilityLabel
       button.addTarget(self, action: action, for: .touchUpInside)
       button.translatesAutoresizingMaskIntoConstraints = false
   }
   ```
2. **`mountBottomControls` — identical constraint shape** (leading/trailing 12pt,
   bottom safe-area −26, 44×44), differing only in which two buttons are pinned:
   Downloader `:121-142` (settings + share), Reader `:349-370` (settings + share,
   same two roles, different button identity for the second one).
3. **`applyCarouselTopInset` — same one-line pattern**, Reader's adds its extra
   chrome-row clearance: Downloader `:115-117` vs Reader `:170-172`.
4. **`cardOffset` + index-mapping helper — identical structure**, only the
   variable/parameter names differ:
   - Downloader `:219-224` (`mediaIndex(forCarouselIndex:)` over `items`)
   - Reader `:413-418` (`articleIndex(forCarouselIndex:)` over `items`)
   ```swift
   private var cardOffset: Int { renderedPasteboardURL == nil ? 0 : 1 }
   private func <index-fn>(forCarouselIndex index: Int) -> Int? {
       let idx = index - cardOffset
       return items.indices.contains(idx) ? idx : nil
   }
   ```
5. **`reload()` — same fingerprint-diff skeleton**: build a fingerprint array from
   `items`, `insert("paste|\(pasteboardURL...)", at: 0)`, bail if unchanged from
   `appliedFingerprint`, capture `oldItemIndex`/`centeredID` before reassigning
   `items`, recompute `centeredIndex` through `cardOffset`, call
   `carousel.reloadData(centeringAt:)`, then toggle `emptyView`/`carousel.view`
   visibility:
   - Downloader `:176-203` (adds `pendingPasteboardDownloadURLString` handling and
     `updateShareButton()` — real behavioral differences, not just noise)
   - Reader `:436-459`
6. **`refreshPasteboardURL()` — same shape, deliberately different pasteboard
   API** (Downloader needs the actual URL value to platform-check and dedupe
   against the store; Reader only needs a boolean "is there a link"): both guard
   on `consumedPasteboardChangeCount == pasteboard.changeCount`, capture
   `changeCount`, dispatch to main, re-check the change count hasn't moved, then
   set `pasteboardURL` and call `reload()`. Downloader `:256-287`
   (`detectValues(for: [\.probableWebURL])`), Reader `:387-411`
   (`detectPatterns(for: [.probableWebURL])`). The *skeleton* (guard/capture/
   dispatch/re-check/reload) is duplicated even though the payload differs.
7. **Empty-state views — identical layout, different text/glyph**:
   `EmptyMediaView` (Downloader `:880-911`) and `EmptyArticlesView` (Reader
   `:1060-1091`) are both `image` (44pt symbol, `.tertiaryLabel`) + `title`
   (`.title3`) + `subtitle` (`.subheadline`, `.secondaryLabel`, `numberOfLines =
   0`) in a `UIStackView` (`spacing: 12`, centered, `leading/trailing
   greaterThan/lessThan ±32`) — every constraint constant matches.
8. **`settingsTapped()` — identical** one-liner
   (`navigationController?.pushViewController(SettingsViewController(), animated:
   true)`) at Downloader `:247-249` / Reader `:381-383`.

Net: roughly 150-200 lines of near-verbatim skeleton across the two files. A
shared abstraction (e.g. a `CardCarouselHostViewController` base class or a small
`PasteboardCardOffsetting`/`EmptyCarouselStateView` set of helpers in
`LunaDesignSystem` or `LunaReadingListUI`) could absorb items 1, 2, 3, 4, 7, 8
outright, and give items 5–6 a shared skeleton with host-supplied hooks for the
parts that generalize differently (payload type, extra bookkeeping). This is the
single highest-leverage structural finding in this audit.

#### B. Two independent resolve/download/mux pipelines for the same platforms

`LiveMediaDownloadManager` (background, URLSession-delegate + persisted
`jobs.json` state machine) and `SocialMediaResolver` + `MediaDownloadService`
(foreground, `async`/continuation-based) implement **the same per-platform
resolution knowledge twice**, in two different idioms:

- Per-platform resolve URL/UA/kind construction:
  `LiveMediaDownloadManager.resolveRequest(for:)` (`:551-606`) vs
  `SocialMediaResolver.resolveX/resolveTikTok/resolveInstagram/resolveFacebook/resolveReddit`
  (`:46-182`). Both know: fxtwitter's JSON endpoint, TikTok's watch page,
  Instagram's `/embed/captioned/` URL, the Facebook plugin→desktop→mobile→canonical
  fallback chain (`facebookVideoPluginURL`, quality/UA choices), and Reddit's
  `/comments/<id>.json`. The background path reuses `SocialMediaResolver
  .facebookVideoPluginURL` and `MediaDownloadHTTP` directly (good — it doesn't
  redefine those), but re-encodes the *sequencing* of the Facebook fallback chain
  as a string-tagged (`"facebookPlugin"`/`"facebookDesktop"`/`"facebookMobile"`/
  `"facebookCanonical"`) resumable state machine spread across three methods:
  `resolveRequest` (`:571-580`, initial `kind`), `resolvedAsset` (`:619-622`,
  parse dispatch), `startNextFacebookResolve` (`:825-859`, fallback advance) —
  because a background job must be resumable after process death, it cannot just
  be a linear `async` function like `SocialMediaResolver.resolveFacebook` (`:96-148`)
  is. This is a **legitimate, documented** duplication (the file's own comments at
  `:571-576` and `:825-828` explain the mirroring intent) rather than an
  accident, but it means the fallback *order* now has two sources of truth that
  must be kept in sync by hand.
- Reddit dual-stream (video+audio) muxing is implemented **twice**, independently:
  - `LiveMediaDownloadManager.startRedditMuxedDownload` (`:725-771`) — for the
    background/job-based engine, using its own `plainDownload` (`:773-786`).
  - `MediaDownloadService.MediaFileDownloader.downloadAndMux` (`:186-217`) — for
    the foreground/continuation-based engine.
  Both: download the video, call the *shared* `RedditAudioFetcher.fetch` for
  audio, call the *shared* `MediaMuxer.mux`, and on audio failure degrade to the
  silent video, on mux failure fall back to the un-muxed video file. The
  degrade/fallback *policy* is duplicated even though the risky primitives
  (`RedditAudioFetcher`, `MediaMuxer`) are correctly shared.
- **Exact duplicate function**, not just similar logic —
  `copyToClipboardIfEnabled(_:)` is defined twice with identical bodies (only a
  local variable name differs, `url` vs `fileURL`):
  - `LiveMediaDownloadManager.swift:916-928`
  - `MediaDownloadService.swift:140-152`
  ```swift
  @MainActor
  private func copyToClipboardIfEnabled(_ item: SavedMediaItem) {
      guard AutoDownloadSettings.autoCopyDownloadsToClipboard,
            let kind = item.kind else { return }
      switch item.storageState {
      case .localFile:
          if let url = item.fileURL { _ = MediaPasteboard.copy(.localFile(url)) }
      case .photosReference(let identifier, _, _):
          _ = MediaPasteboard.copy(.photo(localIdentifier: identifier, kind: kind))
      case .undownloaded:
          break
      }
  }
  ```
  This one is pure duplication with no documented reason (unlike the Facebook
  state-machine mirroring above) — a natural candidate for a single `@MainActor`
  free function in `MediaItemProvider.swift` (which both files already import
  transitively) that both call sites replace with a one-line call.

#### C. Duplication inside `LiveMediaDownloadManager` itself

- **The media-download `URLRequest` construction (UA header + conditional TikTok
  Referer) is repeated verbatim four times**, all producing the exact same
  3-statement block for the same `assetURL`/`sourceURL` pair:
  - `startMediaDownload(for:asset:)` — `:313-318`
  - `restartTransfer(for:)`, `.downloading` case — `:395-399`
  - `resume(jobID:)` — `:481-485`
  - `retryOrFail(...)`, `.media` case — `:969-973`
  ```swift
  var request = URLRequest(url: assetURL, timeoutInterval: 60)
  request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
  if sourceURL.host?.lowercased().contains("tiktok") == true {
      request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
  }
  ```
  A private `mediaAssetRequest(assetURL: URL, sourceURL: URL) -> URLRequest`
  helper would collapse all four sites.
- **`makeThumbnail(from:jobID:)` (`:630-650`) and `makeVideoThumbnail(from:jobID:)`
  (`:652-666`)** both do "generate one `CGImage`, then
  `CGImageDestinationCreateWithURL` → `AddImage` → `Finalize` at
  `JobStore.thumbnailURL(fileName: "\(jobID).jpg")`" — only the CGImage source
  differs (`CGImageSourceCreateThumbnailAtIndex` from downloaded bytes vs
  `AVAssetImageGenerator.copyCGImage`). The JPEG-write tail (5 lines) is
  duplicated.
- **`resumePendingWiFiDownloads()` (`:416-421`) and `startAllPendingWiFiDownloads()`
  (`:427-431`)** are both "loop `AutoDownloadSettings.pendingWiFiDownloadURLs()`
  and call `start(urlString:ownership:...)`" — they differ only in the network
  guard and `manual:` flag, but are written as two independent `for` loops rather
  than one loop with a parameter.

None of the above are proposed as changes here (read-only audit) — they're
extraction seams for a later pass.

### 2.4 Overly complex code

**`LiveMediaDownloadManager.swift` (1462 lines) — region map:**

| Lines | Region | Note |
|---|---|---|
| 19-129 | Module-level policy/notification free functions and small public enums (`LiveMediaDownloadOwnership`, `LiveMediaDownloadStartPolicy`, `LiveMediaDownloadResumePolicy`, `WiFiOnlyDownloadGate`, `DownloaderJobPhase`, `DownloaderJobSnapshot`, `postDownloaderJobProgress`, `postDownloaderJobEnded`) | Genuinely file-scoped helpers; fine where they are. |
| 131-280 | `LiveMediaDownloadManager` class + **`start(urlString:...)`** (`:156-280`, ~125 lines) | The god-method: reap-suspensions → canonicalize Reddit URL → platform-support check → determine ownership → `ensureUndownloaded` → downloader-start-policy gate → Wi-Fi gate → Photos-permission gate → existing-job dedup/orphan-repair-and-restart → new-job creation → `resolveRequest` → `startTask` → activity start. 9 sequential concerns in one function with ~8 early returns. Extraction seam: split into `gateAndPrepare(urlString:...) -> GateResult` (everything through the Wi-Fi/permission checks) + `attachToExistingJobIfPresent(...)` (the `store.jobs().first(where:...)` block, `:218-242`) + `createAndStartJob(...)` (`:244-279`). |
| 282-320 | `startMediaDownload(for:asset:)` | Reasonable size; contains the request-construction duplicate (§2.3C). |
| 321-347 | `attachBackgroundCompletionHandler` / `resumeLiveActivities` | Small, fine. |
| 349-409 | `activeTaskJobIDs()` / **`restartTransfer(for:)`** (`:363-409`) | The `.downloading` case (`:380-394`) can recurse once into itself via a reset to `.resolving` (`:387-393`, `await restartTransfer(for: job)`) when the persisted asset URL is missing — bounded (phase is `.resolving` on the recursive call, which can't hit that branch again), but worth a code comment noting the recursion is intentionally single-level; today the "resets and calls itself" pattern reads like it could loop. |
| 411-431 | `resumePendingWiFiDownloads` / `startAllPendingWiFiDownloads` | Near-duplicate loops (§2.3C). |
| 433-508 | `currentDownloadProgress` / `suspend(jobID:)` / **`resume(jobID:)`** (`:462-500`) / `reapExpiredSuspensions` | `resume` re-derives the request-construction duplicate (§2.3C) and duplicates the resolve-request path inline rather than delegating to `restartTransfer`, even though the two do almost the same thing from a `.suspended` job. |
| 510-531 | `canonicalRedditURLStringIfNeeded` / `title(for:)` | Small, fine. |
| 533-606 | `startTask` / `cancelTasks` / **`resolveRequest(for:)`** (`:551-606`) | The per-platform resolve switch — see §2.3B for the duplication-with-`SocialMediaResolver` angle. |
| 608-666 | `resolvedAsset(from:job:)` / `makeThumbnail` / `makeVideoThumbnail` | Thumbnail-write duplication, §2.3C. |
| 668-771 | `finish` / `finalizeDownloadedFile` / **`startRedditMuxedDownload`** (`:725-771`) | Reddit-only special path; duplication vs `MediaFileDownloader.downloadAndMux`, §2.3B. |
| 773-797 | `plainDownload` / `reportProgress` | Small, fine. |
| 799-859 | `finishResolve` / **`startNextFacebookResolve`** (`:825-859`) | Facebook-fallback state machine, §2.3B. |
| 861-928 | `save` / `finishDownloaderStorage` / `copyToClipboardIfEnabled` | Exact-duplicate function, §2.3B. |
| 930-1017 | `retryOrFail` / `isTransient` / `failJob` / `tearDownSuspendedJob` | Reasonable. |
| 1020-1099 | `URLSessionDownloadDelegate` conformance | Progress-throttling (`didWriteData`, `:1021-1051`) mixes percent-change gating for the in-process notification with a *separate* whole-percent-or-phase-change gate for `updateActivity` — two similar-but-not-identical throttle conditions computed from the same `previousPercent`/`percentChanged`/`phaseChanged` locals; correct as written, just dense. |
| 1101-1112 | `TaskRole` / `taskParts` | Small, fine. |
| 1114-1253 | **ActivityKit private extension** (`startActivity`/`startFailedActivity`/`updateActivity`/`endActivity`/`activityState`, ~140 lines) | Self-contained region with no dependency on the manager's stored properties other than nothing (all params passed in) — a clean, mechanical candidate to move to its own file (e.g. `LiveMediaDownloadManager+ActivityKit.swift`) purely for file-size/organization, no behavior change. |
| 1255-1337 | `LiveMediaDownloadJob` model (~85 lines) | Also a clean candidate for its own file. |
| 1339-1462 | `JobStore` (persistence, ~125 lines) | Also a clean candidate for its own file; it already reads as a self-contained unit (own lock, own cache, own progress-persist-throttle). |

**Redundant state flags:** none found that are demonstrably unused — `resolveKind`
(`String?`, not an enum) is the one modeling smell: it's a stringly-typed
mini-state-machine (9 distinct string literals across `resolveRequest`,
`resolvedAsset`, `startNextFacebookResolve`) where a typo would silently fail to
match any switch case rather than fail to compile. Not a functional bug today
(every string is spelled consistently), but it's the reason the Facebook
fallback chain in §2.3B is duplicated as *strings* instead of as a shared enum
the two engines could both switch on.

**`SavedMediaCardsViewController.swift` (911 lines):** no god-methods — the
largest method is `reload()` at 28 lines (`:176-203`) and
`contentControllerForCardAt` at 49 lines (`:425-478`, a straightforward
`storageState`/`kind` dispatch, not complex logic). The file's size comes from
five nested types (two card-content controllers, a progress ring view, an empty
state view), each small and single-purpose — no extraction seam needed inside
this file beyond the cross-file duplication already covered in §2.3A.

### 2.5 Dead/unused code

Every claim below is a repo-wide grep, excluding `.build*`/`build/` and the
stale `.claude/worktrees/agent-a44f9578d823e01c8/` sandbox.

- **Not dead** (confirmed live, listed because they looked suspicious at first
  read): `LiveMediaDownloadResumePolicy` (`grep -rn "LiveMediaDownloadResumePolicy"` →
  used at `LiveMediaDownloadManager.swift:230,332` + 6 assertions in
  `LiveMediaDownloadJobTests.swift`), `MediaPreviewFetcher` (used once, by
  `LunaShareSurface/SavedNonTextualViewController.swift:972` — legitimate
  cross-module reuse, not dead, just single-consumer).
- **`SavedMediaStore.item(id:)`** (`SavedMediaStore.swift:292-294`) — `grep -rn
  "\.item(id:"` (excluding worktrees) finds only three call sites, and all three
  are in `LunaTests/SavedMediaStoreTests.swift:45,69,83`. No production call site
  exists in the current tree — the only non-test caller was
  `SavedMediaViewerViewController.swift`, which lived in the pre-carousel
  Photos-grid UI and has since been deleted (it only still exists in the stale
  worktree). This is **test-only public API**, not "dead" in the sense of never
  executing, but it's no longer serving its original production purpose and is
  worth flagging: either a real future consumer will need it, or the test should
  go through `items().first(where:)` like every other store-reader in this file
  does.
- **Everything else checked is live.** Spot-checked and confirmed used:
  `attachBackgroundCompletionHandler`, `resumeLiveActivities`,
  `resumePendingWiFiDownloads`, `startAllPendingWiFiDownloads`,
  `currentDownloadProgress`, `.suspend(jobID:)`/`.resume(jobID:)` (used
  exclusively by `LunaDownloaderLiveActivityWidget.swift`'s two `AppIntent`s —
  confirmed no other caller exists anywhere in the app), `wasInstalled
  (surfaceIdentifier:)` (used by `Luna/Settings/InstalledAppMarkers.swift:30`),
  `requiresForegroundRequest` (used by `Luna/Mail/Intents/ProvideContextIntent.swift`),
  `existingDownloadedItem` (used by `MediaAutoDownloader` +
  `SavedNonTextualViewController` + tests).
- **Possible asymmetry, not dead code:** `AutoDownloadSettings.platforms` (`:80`)
  lists 4 platforms (`.x, .instagram, .tiktok, .facebook`) while
  `MediaDownloadablePlatform.supported` (`MediaDownload.swift:65`) lists 5 (adds
  `.reddit`). `grep -rn "AutoDownloadSettings\.platforms"` shows its only
  consumer is `Luna/Settings/AutoDownloadSettingsScreen.swift:15`, the per-platform
  toggle list — so Reddit auto-download has no user-facing per-platform toggle.
  This may well be intentional (Downloader's own downloads bypass the
  per-platform toggle entirely via `isRunningInDownloader ||
  AutoDownloadSettings.isEnabled(for:)` in `MediaAutoDownloader.isEnabled`,
  `:19-23` — the toggle only gates sibling-app Photos auto-save), but it's an
  asymmetry worth a maintainer's eyes since it's easy to lose track of which of
  the two platform lists is authoritative for what.
- **`MediaMuxer`, `PhotoLibrarySaver`, `MediaDownloadService`,
  `ClipLaunchURL`, `RedditAudioFetcher`, `MediaItemProviderFactory`/
  `MediaPasteboard`** all have zero dedicated test files (see §3) but are not
  dead — all confirmed live via the usage table in §1.

### 2.6 Comment hygiene

- `LiveMediaDownloadManager.swift:271-273`:
  > ```
  > // Register the durable background task before any UI-facing callback.
  > // This closes the persist-without-task window that used to leave a
  > // forever-resolving row if the app terminated during the callback.
  > startTask(...)
  > ```
  The second/third lines narrate a historical bug fix rather than describing
  current behavior. **Rewrite:**
  ```swift
  // Register the durable background task before any UI-facing callback, so a
  // process death right after this point still has a real transfer to resume —
  // never just a persisted job stuck at "resolving" forever.
  startTask(...)
  ```
- `SocialMediaResolver.swift:60-64`:
  > ```
  > // Embed page FIRST. Its `contextJSON` (gql_data.shortcode_media) carries the
  > // real `video_url` for reels/videos and `display_url` for stills — the only
  > // reliable keyless source. The crawler `og:` tags now expose ONLY the poster
  > // image behind a login wall, so a video reel would otherwise save a still
  > // (the bug this fixes). `/p/{code}/embed/` serves reels too.
  > ```
  "(the bug this fixes)" is change narration bolted onto an otherwise-fine
  explanatory comment. **Rewrite** (drop the parenthetical, keep the rest as-is):
  ```swift
  // Embed page FIRST. Its `contextJSON` (gql_data.shortcode_media) carries the
  // real `video_url` for reels/videos and `display_url` for stills — the only
  // reliable keyless source. The crawler `og:` tags expose ONLY the poster image
  // behind a login wall, so relying on them would save a still for a video reel.
  // `/p/{code}/embed/` serves reels too.
  ```
- Everything else flagged by the "used to / previously / legacy / no longer"
  sweep is legitimate and should stay as-is: `SavedMediaStore.swift:146-148,166`
  (`legacyFileName`) and `SavedMediaItem.StorageState`'s doc comment both
  describe an *actually still-decoded* legacy JSON shape, not a narrated fix;
  `LiveMediaDownloadManager.swift:1288-1290` (`"Nil only for jobs written by
  older builds..."`) documents a real, still-relevant nullability rule on
  `ownership`; `MediaAutoDownloader.swift:27` ("legacy Photos destination") and
  `PhotoLibrarySaver.swift:56` ("no longer resolves") both describe present-tense
  behavior, not history.

### 2.7 Animation structure

- **Scrub-preview handoff** (`CardCarouselViewController.swift:717-885`, out of
  this audit's file list but the mechanism Downloader depends on via
  `style.autoplaysScrubPreviewContent = true`,
  `SavedMediaCardsViewController.swift:50`): this is well-structured, not ad hoc.
  `mountPreviewContent`/`takeScrubPreviewContent`/`promoteScrubPreview` form a
  clean three-step protocol (mount into the overlay while scrubbing → detach
  without pausing when committed → re-parent into the real card slot at
  `:852-885`), with an explicit comment (`:849-851`) stating the invariant ("no
  player swap … keeps playing at its current timestamp"). Downloader's contract
  with this is entirely declarative: it returns the *same* content controller
  from both `contentControllerForCardAt` and `previewContentControllerForCardAt`
  (`SavedMediaCardsViewController.swift:480-485`), so the carousel's
  promote-without-rebuilding logic just works. Nothing ad hoc on the Downloader
  side.
- **Autoplay transitions**: `CardContentViewController.cardDidBecomeCentered()`/
  `cardDidLeaveCenter()` (`LunaDesignSystem`) are the single seam every playable
  card type honors; Downloader adds no autoplay logic of its own — it inherits
  it entirely through `VideoCardContentViewController`/
  `AnimatedImageCardContentViewController`. This is exactly the "one header, one
  layout, no bespoke choreography" structure the module doc comment
  (`SavedMediaCardsViewController.swift:5-11`) claims.
- **Downloader-local animation**: `CircularDownloadProgressView`
  (`SavedMediaCardsViewController.swift:831-876`) uses a `CABasicAnimation` on
  `strokeEnd` keyed off the presentation layer's current value
  (`:836`, `progressLayer.presentation()?.strokeEnd ?? oldValue`) — a correct,
  minimal pattern for smoothly animating repeated progress updates without
  building an explicit animation queue. Not over-structured, not ad hoc; no
  finding here.
- **`DownloaderProgressFooterView`** (`LunaReadingListUI`, out of this audit's
  file list but Downloader-owned in spirit) does a plain `UIView.animate` show/
  auto-hide (`:158-166`) with a cancelable `DispatchWorkItem` for the delayed
  hide — simple and correct, no over-engineering.

---

## 3. Test coverage note

`LunaTests` files exercising this part, and what they actually cover:

| Test file | Covers |
|---|---|
| `AutoDownloadSettingsTests.swift` (8 tests) | `AutoDownloadSettings` toggles/round-trips, `MediaRetentionSettings`/`MediaRetentionOption`, pending-Wi-Fi-download mark/unmark, `LunaInstallationMarkers` durability, `MediaAutoDownloader.shouldStartDownloaderIntentDownload` preflight. |
| `LiveMediaDownloadJobTests.swift` (12 tests) | `LiveMediaDownloadStartPolicy`, `LiveMediaDownloadResumePolicy`, `WiFiOnlyDownloadGate` (all 5 cases), `LiveMediaDownloadJob` Codable round-trip incl. the legacy-no-`ownership` decode path, main-thread delivery of `.downloaderJobProgressChanged`, and one integration-style Facebook-reel background-resolution test. |
| `SocialMediaResolverTests.swift` (11 tests) | Facebook plugin→desktop→mobile→canonical fallback chain (the exact chain duplicated in `LiveMediaDownloadManager`, §2.3B — only the foreground copy is under test), Instagram/TikTok parser precedence rules. |
| `RedditMediaParserTests.swift` (8 tests) | `RedditMediaParser` (silent/audio video, DASH-manifest fallback, crosspost recursion, malformed/non-video listings) — the pure-parser half of the Reddit path only. |
| `SavedMediaStoreTests.swift` (10 tests) | `SavedMediaItem`/`StorageState` round-trip incl. legacy `fileName` decode, undownloaded↔local↔Photos transitions, dedup-by-platform-item-id, stat-token cache invalidation across store instances, cross-thread change notification. |
| `IntentMediaExportNamingTests.swift` (3 tests) | `MediaAutoDownloader.IntentMediaExportNaming` filename sanitization/fallback only. |

**Gaps** (no dedicated test file; confirmed by
`grep -rln "<Type>" LunaTests/` returning nothing):

- `MediaMuxer` — no test exercises the AVFoundation mux path at all (video-only,
  video+audio, or its two throw cases).
- `PhotoLibrarySaver` — no test (reasonable given it's a thin PhotoKit wrapper
  that needs a real photo library, but the pure bits — `preferredResource`
  selection order — are untested).
- `MediaDownloadService` / `MediaFileDownloader` — no direct test; only
  exercised transitively through `MediaAutoDownloader`'s tests, which stub the
  service protocol rather than hitting `MediaDownloadService` itself. The
  Reddit-mux fallback policy inside `MediaFileDownloader.downloadAndMux`
  (§2.3B) has no test on either copy.
- `RedditAudioFetcher` — no direct test (its two-tier fallback — guessed path,
  then DASH-manifest parse — is untested end to end; `RedditMediaParserTests`
  only tests the manifest-parsing pure function it calls).
- `ClipLaunchURL` — no test file for `LunaDownloaderClip` at all.
- `SavedMediaCardsViewController` and `PhotosReferenceBadgeView` — no UI/
  snapshot test exists for either (confirmed: no `SavedMediaCards` string
  appears anywhere under `LunaTests/`). Given the CLAUDE.md-documented
  snapshot-testing pattern used for Reader/CatchUp screens, this is a real gap:
  the Downloader root screen's card-adapter logic (`storageState`/`kind`
  dispatch, pasteboard-card offset math, context-menu construction) is currently
  verified only by manual/Blitz-driven testing, never by CI.
- `LunaDownloaderLiveActivityWidget`'s two `AppIntent`s (`Suspend`/`Resume`) have
  no test — they're thin pass-throughs to already-tested manager methods, so the
  risk is low, but the intents' own `perform()` wiring is unverified.

---

## Top 10 highest-value changes (ranked)

1. **(L)** Extract the shared skeleton between `SavedMediaCardsViewController`
   and `ArticleCardsViewController` (§2.3A: `configureBottomButton`,
   `mountBottomControls` shape, `applyCarouselTopInset`, the
   `cardOffset`/index-mapping pair, the `reload()` fingerprint-diff skeleton, the
   empty-state view, `settingsTapped`) into a shared base or helper type. Largest
   line-count win in this audit (~150-200 duplicated lines) and directly
   addresses the task's explicit ask.
2. **(M)** Split `LiveMediaDownloadManager.swift` into
   `LiveMediaDownloadJob.swift` (model), `JobStore.swift` (persistence), and
   `LiveMediaDownloadManager+ActivityKit.swift` (the ActivityKit extension) —
   all three regions are self-contained (§2.4) and moving them is purely
   organizational.
3. **(S)** Delete the exact-duplicate `copyToClipboardIfEnabled` in one of
   `LiveMediaDownloadManager.swift`/`MediaDownloadService.swift` and share the
   other (§2.3B) — smallest, safest, most obviously-correct dedup in this audit.
4. **(S)** Extract the 4×-repeated media-download `URLRequest` construction
   (UA + conditional TikTok Referer) in `LiveMediaDownloadManager` into one
   private helper (§2.3C).
5. **(M)** Break up `LiveMediaDownloadManager.start(urlString:...)` (~125-line
   god-method, §2.4) into named sub-steps (gate/attach-existing/create-new).
6. **(M)** Decide whether the Facebook fallback chain's string-tagged
   `resolveKind` state machine (duplicated across `resolveRequest`/
   `resolvedAsset`/`startNextFacebookResolve`, §2.3B/§2.4) should become a real
   `enum` shared with `SocialMediaResolver`, so the fallback *order* has one
   source of truth instead of two hand-synchronized copies.
7. **(S)** Fix the two change-narration comments (§2.6: `LiveMediaDownloadManager
   .swift:271-273`, `SocialMediaResolver.swift:60-64`) with the rewrites given
   above.
8. **(M)** Add a snapshot/unit test for `SavedMediaCardsViewController`'s
   data-adapter logic (storage-state/kind dispatch, pasteboard-card offset math,
   context-menu construction) — currently the only card-carousel host with zero
   test coverage (§3), unlike the Reader equivalent's broader test net.
9. **(S)** Add a unit test for `MediaMuxer.mux` (video-only track, video+audio
   mux, both throw paths) — the one piece of AVFoundation logic in this module
   with literally no test today (§3).
10. **(S)** Dedupe the two near-identical thumbnail-write tails
    (`makeThumbnail`/`makeVideoThumbnail`, §2.3C) and the two near-identical
    pending-Wi-Fi-download loops (`resumePendingWiFiDownloads`/
    `startAllPendingWiFiDownloads`, §2.3C) inside `LiveMediaDownloadManager`.
