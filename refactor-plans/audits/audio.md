# Audio audit — `LunaLibraries/Sources/LunaAudioPlayback/` + `Luna/MiniPlayer/`

Scope: 20 files in `LunaAudioPlayback` + `AudioMiniPlayerView.swift`/
`MiniPlayerHostViewController.swift` in `Luna/MiniPlayer/`. Every file was read
in full. Read-only audit — no code changed, no functionality-change proposals.
Cross-referenced against `claudedocs/audio-playback.md` and against the two
prior cleanup passes (`CODE_REVIEW_PLAN.md`, `PERF_REVIEW_PLAN.md`) — nothing
below duplicates an item already fixed or deliberately deferred there.

Note: a stray `.claude/worktrees/agent-a44f9578d823e01c8/` directory contains
a full duplicate checkout of these same files. It is noise from an unrelated
agent run, not a second copy of the module — ignored throughout this audit
(all line numbers below refer to the real tree under `LunaLibraries/` and
`Luna/`).

---

## 1. Structure map

### Render-to-buffer pipeline

- **`SpeechRenderer.swift`** (275 ln) — offline synthesis via
  `AVSpeechSynthesizer.write(_:toBufferCallback:)`; normalizes every buffer to
  one canonical float32 format; captures word timings. Public API:
  `WordMarker`, `RenderedSegment`, `SpeechRenderer` (`render(_:) async throws`,
  `canonicalFormat`, `renderTimeout`), `SpeechRenderer.RenderError`. Used by:
  `AudioPlaybackCenter` (via the `SpeechRendering` seam in
  `AudioPlaybackSeams.swift`), `ArticleAudioEngineTests`/`AudioPlaybackTestFakes`
  (fakes conform to `SpeechRendering`), `SpeechRendererSpikeTests`.
- **`AudioVoiceResolution.swift`** (47 ln) — standalone voice-picking
  (best enhanced/premium voice, simulator no-op). Internal (`enum`, no
  `public`). Used only by `SpeechRenderer.render(_:)`.
- **`AudioFormatConversion.swift`** (61 ln) — shared `AVAudioConverter`
  buffer-list conversion. Internal (`enum`, no `public`). Used by
  `SpeechRenderer.normalize` and `ToneLibrary.loadBuffer`.
- **`ToneLibrary.swift`** (59 ln) — loads/converts the two bundled chime
  `.caf` assets. Public: `ToneAsset`, `ToneLibrary.loadBuffer`. Used by
  `ArticleAudioEngine.cachedToneBuffer`; asserted directly by
  `ToneAssetTests`/`AudioFormatConversionTests`.
- **`ArticleAudioEngine.swift`** (280 ln) — the long-lived
  `AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixerNode` graph; sample-
  accurate `currentTime`, low-water-mark callback, tone/segment scheduling,
  rate pinning, test-only manual-rendering pump. Public: `ArticleAudioEngine`,
  `SegmentRateMode`, `ArticleAudioEngineError`. Used by: `AudioPlaybackCenter`
  (via `ArticleAudioEngineControlling`), `ArticleAudioEngineTests` directly.

### Center + system integration

- **`AudioPlaybackCenter.swift`** (874 ln) — app-wide singleton, single owner
  of playback: state machine, render/schedule pump, autoplay chain, seek/skip,
  position persistence, external pause/resume. Public surface is large:
  `AudioPlaybackState`, `AudioPlaybackItemInfo`, `AudioWordEvent`,
  `AudioPlaybackHandoff`, `AudioPlaybackSnapshot`, `AudioPlaybackObserver`,
  `AudioPlaybackCenter` itself (`shared`, `play`, `togglePlayPause`, `pause`,
  `resume`, `restorePersistedSessionIfAvailable`,
  `restorableHandoffIfAvailable`, `skipForwardParagraph`,
  `skipBackwardParagraph`, `skip(bySeconds:)`, `seek(toFraction:)`,
  `cycleRate`, `setRate`, `nextItemProvider`, `scriptProvider`,
  `scriptPrefetchHandler`, `currentSnapshot`, `currentItemInfo`, `state`,
  `addObserver`/`removeObserver`). Used by: `Luna/AudioPlaybackWiring.swift`,
  `Luna/AudioScriptPipelineWiring.swift`, `Luna/Mail/Intents/ReadArticleIntent.swift`,
  `Luna/MiniPlayer/MiniPlayerHostViewController.swift`,
  `LunaLibraries/Sources/LunaReaderUI/ReaderAudioLauncher.swift` (the sole
  in-module seam — nothing else in `LunaReaderUI` may touch `.shared`
  directly, per that file's header comment).
- **`AudioPlaybackSeams.swift`** (95 ln) — `QueueCandidate` +
  `ReadingListPlaybackStore`, `ReadingListScriptSource`, `SpeechRendering`,
  `ArticleAudioEngineControlling`, `AudioSessionControlling` protocols, each
  with a same-file structural conformance for the real type. Pure
  test-seam plumbing; no logic. Used throughout the module and by
  `LunaTests/AudioPlaybackTestFakes.swift`.
- **`AudioPlaybackWordIndexing.swift`** (94 ln) — pure global-word-index ↔
  per-block-range mapping helpers (`wordCount`, `blockStartWordIndices`,
  `spokenBlockPosition`, `wordStartUTF16Offsets`, `wordOffset`), plus the
  `Array.subscript(safe:)` helper. Internal (`enum`, no `public`). Used only
  by `AudioPlaybackCenter`; asserted directly by `AudioWordIndexingTests`.
- **`AudioPlaybackPositionStore.swift`** (88 ln) — App-Group-`UserDefaults`
  round-trip of one resumable `Position` (itemID/wordIndex/elapsed/title/
  savedAt). Public: `AudioPlaybackPositionStore`, `.Position`. Used by
  `AudioPlaybackCenter` only; asserted by `AudioPlaybackPersistenceTests`,
  `AudioPlaybackHandoffTests`.
- **`AudioSessionCoordinator.swift`** (122 ln) — the new-path
  `AVAudioSession` choke point: `.playback`/`.spokenAudio`, interruption/
  route-change → `Action` (`pause`/`resume`/`none`), grace-period
  deactivation. Public: `AudioSessionCoordinator`, `.Action`. Used by
  `AudioPlaybackCenter` (via `AudioSessionControlling`); asserted by
  `AudioSessionCoordinatorTests`.
- **`NowPlayingCoordinator.swift`** (343 ln) — owns
  `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` for the new path; artwork
  decode/caching; re-binds targets on every non-idle transition (legacy-
  conflict handoff — see §2.6). Public: `NowPlayingInfoSink`,
  `RemoteCommandBinding`, `NowPlayingCoordinator` (`.shared`,
  `registerAtLaunch`, `.Command`), `SystemNowPlayingInfoSink`,
  `SystemRemoteCommandBinding`. Used by `Luna/AudioPlaybackWiring.swift`
  (`registerAtLaunch`); asserted by `NowPlayingCoordinatorTests`.
- **`AudioSettings.swift`** (62 ln) — App-Group `UserDefaults` prefs:
  `isAutoplayEnabled`, `isIntelligentTrimmingEnabled`, `preferredRate`
  (clamped to `rateSteps`). All `public static`. Used by:
  `AudioPlaybackCenter`, `AudioScriptPipeline`, `ExtensionAudioScriptResolver`,
  `Luna/Settings/AudioSettingsScreen.swift`,
  `Luna/MiniPlayer/MiniPlayerHostViewController.swift`; asserted by 6 test
  files.

### Trimming pipeline

- **`AudioScript.swift`** (83 ln) — `SpokenBlock`/`AudioScript` value type +
  the `passthrough` factory + `builderVersion` constants. Public throughout.
  Used by every other trimming file, `AudioPlaybackCenter` (default
  `scriptProvider`, handoff word-count estimate), `MiniPlayerHostViewController`
  (transitively via display data only). Asserted by `AudioScriptTests`,
  `AudioMiniPlayerTests`.
- **`AudioTrimHeuristics.swift`** (304 ln) — deterministic whole-block
  classifier (caption/credit/marker/link-density/byline/dateline/share-prompt
  signals; leading/trailing edge runs; global ~50% cap with degrade). Public:
  `classify`, `looksLikeRemovableJunk`, `Result`; `wordCount(text:)` is
  package-internal (`static`, no `public`). Used by `AudioScriptPipeline`,
  `AudioTrimIntelligence`, `ExtensionAudioScriptResolver`,
  `ExtensionAudioScriptWriter`. Asserted by `AudioTrimHeuristicsTests`.
- **`AudioTrimIntelligence.swift`** (354 ln) — optional async on-device-LLM
  refinement over the heuristic survivors: chunking, positional acceptance
  rule, per-chunk/global-cap validation, error taxonomy. Public:
  `AudioTrimModelError`, `AudioTrimModelSession` protocol,
  `UnavailableTrimSession`, `FoundationModelsTrimSession` (`@available(iOS
  26, *)`), `AudioTrimIntelligence.refine`/`RefinementResult`. Used by
  `AudioScriptPipeline`, `ExtensionAudioScriptResolver`. Asserted by
  `AudioTrimIntelligenceTests`.
- **`AudioTrimModelSessionFactory.swift`** (25 ln) — the one `#available`
  gate deciding `FoundationModelsTrimSession` vs `UnavailableTrimSession`.
  Used by `AudioScriptPipeline`'s and `ExtensionAudioScriptResolver`'s
  default `modelSessionFactory` parameter. **No dedicated test file** (see
  §3).
- **`AudioScriptStore.swift`** (86 ln) — sibling-JSON cache I/O keyed off
  `contentFileName`; version-checked load. Public: `AudioScriptCacheEnvelope`,
  `AudioScriptStore` (`load`/`save`/`remove`/`scriptFileName`,
  `currentBuilderVersion`). Used by `AudioScriptPipeline`,
  `ExtensionAudioScriptResolver`, `ExtensionAudioScriptWriter`. Asserted by
  `AudioScriptStoreTests`.
- **`AudioScriptPipeline.swift`** (249 ln) — main-app-only orchestration:
  `install()` (notification/foreground/background observers + launch sweep),
  `script(for:content:)` (playback-time lookup, never blocks on the LLM),
  `prefetch`, sweep, in-flight bookkeeping, `buildScript(content:
  droppedBlockIndices:)` (shared block-builder, also called from
  `ExtensionAudioScriptResolver`). Used by `Luna/AudioScriptPipelineWiring.swift`,
  `Luna/AppDelegate.swift`, `Luna/ArticleSpotlightIndexWiring.swift`. Asserted
  by `AudioScriptPipelineTests`.

### Extension audio (Phase 6)

- **`ExtensionAudioScriptResolver.swift`** (141 ln) — extension-safe
  best-available-script resolution + cancellable opportunistic refinement.
  Public: `ExtensionAudioScriptResolver` (`bestAvailableScriptForImmediatePlayback`,
  `cancelInFlightRefinement`). Used only by
  `LunaLibraries/Sources/LunaReaderUI/ScrollReaderViewController.swift`
  (owns the instance, cancels it in `deinit`). Asserted by
  `ExtensionAudioScriptResolverTests`.
- **`ExtensionAudioScriptWriter.swift`** (46 ln) — one static entry point,
  `writeHeuristicScriptIfNeeded`. Used only by
  `LunaLibraries/Sources/LunaShareSurface/ShareSurfaceDriver.swift` (from
  `persistArticle`). Asserted by `ExtensionAudioScriptWriterTests`.

### UI (`Luna/MiniPlayer/`)

- **`AudioMiniPlayerView.swift`** (290 ln) — passive glass bar: `BarMode`
  (`hidden`/`full`/`slim`), `Display` value type, 6 control closures, subview
  layout, thumbnail decode/cache. `internal` (no `public` — app-target file,
  not a library). Used only by `MiniPlayerHostViewController`; its pure
  `barMode(state:hasMeldAnchor:)` and `Display`/snapshot behavior asserted by
  `AudioMiniPlayerTests`.
- **`MiniPlayerHostViewController.swift`** (373 ln) — window-level container:
  wraps the main nav controller, observes `AudioPlaybackCenter` +
  `AudioMiniPlayerMeld`, drives bar show/hide/slim animation, Phase-6
  handoff-preview display, tap-to-return navigation (delegated to the pure
  `MiniPlayerNavigation` enum + `ReaderItemContaining` protocol). `internal`.
  Instantiated by `Luna/SceneDelegate.swift`. Only its pure helpers
  (`MiniPlayerNavigation.stackIndex`) are directly asserted — see §3.

---

## 2. Findings

### 2.1 Stored-callback communication

Inventory of every closure member used for cross-component communication
(one-shot completion handlers excluded):

| Owner | Closure | Set by | Invoked by |
|---|---|---|---|
| `AudioPlaybackCenter.nextItemProvider` (line 177) | `(() -> QueueCandidate?)?` | `Luna/AudioPlaybackWiring.swift` install() | `handleArticleBodyFinished` (line 691) |
| `AudioPlaybackCenter.scriptProvider` (line 187) | `(ReadingListItem, ArticleContent) -> AudioScript` | `Luna/AudioScriptPipelineWiring.swift` install() | `beginPlayback` (line 487) |
| `AudioPlaybackCenter.scriptPrefetchHandler` (line 196) | `((ReadingListItem, ArticleContent) -> Void)?` | `Luna/AudioScriptPipelineWiring.swift` install() | `handleArticleBodyFinished` (line 698) |
| `AudioSessionCoordinator.actionHandler` (`AudioPlaybackSeams.swift`/`AudioSessionCoordinator.swift:39`) | `((Action) -> Void)?` | `AudioPlaybackCenter.init` (line 303-309), once | `AudioSessionCoordinator.handleInterruption`/`handleRouteChange` |
| `ArticleAudioEngine.needsMoreAudioHandler` (line 66) | `(() -> Void)?` | `AudioPlaybackCenter.handleRendered` (line 627), once per engine instance | `ArticleAudioEngine.checkLowWaterMark` |
| `AudioMiniPlayerView.onTapArticle`/`onSkipBack`/`onPlayPause`/`onSkipForward`/`onCycleRate`/`onToggleAutoplay` (lines 60-65) | plain closures | `MiniPlayerHostViewController.wireControls()` (lines 95-113), once | button `@objc` handlers (lines 266-270) |

Three of these (`nextItemProvider`/`scriptProvider`/`scriptPrefetchHandler`)
are all app-shell dependency-injection seams on the same singleton, but
installed from two *different* wiring files at two different call sites
(`AudioPlaybackWiring.install()` then `AudioScriptPipelineWiring.install()`,
in that order — order matters, since `AudioScriptPipelineWiring` overwrites
`scriptProvider`'s default). A single `AudioPlaybackCenterDelegate` protocol
would reduce the closure count to one stored `weak var delegate`, but would
also force the two independently-owned wiring concerns (queue ordering vs.
trimming) into one type; given `LunaAudioPlayback` deliberately keeps them
decoupled (per `AudioPlaybackWiring.swift`'s own header comment about
avoiding over-coupling), this is a **defensible design as-is** — flagged for
awareness, not recommended.

The `AudioMiniPlayerView` 6-closure set is the standard "passive view exposes
closures, controller wires them" UIKit pattern, and the file's own header
comment explains why (`Display`-value snapshot-testability). Consolidating
into a delegate protocol would *reduce* snapshot-testability (tests currently
stub closures inline; a protocol would need a conforming mock). **Not a
finding** — included in the table for completeness per the audit brief.

`AudioPlaybackObserver` (`AudioPlaybackCenter.swift:106-122`) is the one
already-consolidated multicast delegate protocol in this module (weak-boxed
observers, default no-op extension) — it is the correct comparison point,
and nothing else in the module needs the same treatment.

### 2.2 View/container boundary violations

- **`MiniPlayerHostViewController` bypasses `AudioPlaybackCenter` for
  autoplay, but not for rate.** Rate changes are properly brokered:
  `onCycleRate = { center.cycleRate(); self?.refreshDisplay() }`
  (`MiniPlayerHostViewController.swift:102-105`) — the center owns
  `AudioSettings.preferredRate` *and* pushes it to the live engine
  (`AudioPlaybackCenter.cycleRate`/`setRate`, lines 470-479). Autoplay is
  not: `onToggleAutoplay = { AudioSettings.isAutoplayEnabled.toggle();
  self?.refreshDisplay() }` (lines 106-109) writes directly to the
  settings model, and `refreshDisplay()` reads `AudioSettings.isAutoplayEnabled`
  directly twice more (lines 227, 239) rather than through any center-owned
  snapshot. The center has no symmetric `toggleAutoplay()`/
  `setAutoplayEnabled(_:)` method, even though it already owns the analogous
  `rate` setting and is the sole reader of `AudioSettings.isAutoplayEnabled`
  at the one place it actually matters for playback
  (`handleArticleBodyFinished`, lines 691/739). Confirmed by grep: `AudioSettings.isAutoplayEnabled` is
  written from exactly one call site in the whole repo
  (`MiniPlayerHostViewController.swift:107`) and it's the mini-player's view
  controller, not the center.
- **`MiniPlayerHostViewController` depends directly on three singletons**
  (`AudioPlaybackCenter.shared`, `AudioSettings`, `ReadingListStore.shared`)
  rather than one seam — `ReadingListStore.shared` is reached for
  `item(withID:)`/`content(for:)`/`articlesDirectory` at lines 220, 245,
  315-317 (announcing-item lookup, thumbnail path, tap-to-return reader
  push). This is defensible (the center's job is playback, not general
  reading-list queries) but it does mean the file has no seam at all for
  substitution in a test — consistent with the coverage gap noted in §3.
- **`NowPlayingCoordinator` touches `UIScreen.main.scale`**
  (`NowPlayingCoordinator.swift:210`) inside its artwork closure. Not a
  view/container violation in the audited sense (it's a system-integration
  coordinator, not a view), but worth flagging alongside: `UIScreen.main` is
  the deprecated multi-scene-unsafe accessor: harmless today (this app has
  one scene per process) but inconsistent with `AudioMiniPlayerView`'s own
  thumbnail path, which correctly reads `traitCollection.displayScale`
  (`AudioMiniPlayerView.swift:253`).
- Everything else respects the seam boundary well: `ArticleAudioEngine` never
  touches `AVAudioSession`/queue concepts (by design, and confirmed by
  reading the whole file); `AudioPlaybackCenter` never imports UIKit;
  `ReaderAudioLauncher.center` is the single crossing point from
  `LunaReaderUI` into `LunaAudioPlayback`, and nothing else in
  `LunaReaderUI`/extensions reaches `AudioPlaybackCenter.shared` directly
  (confirmed by repo-wide grep — the only non-wiring hits are
  `ReaderAudioLauncher.swift` and `ReadArticleIntent.swift`, both documented
  crossing points).

### 2.3 Duplicated or disjoint-but-related logic

- **`beginPlayback` and `restartPlayback` share a ~12-line, near-identical
  session-reset block**, repeated verbatim
  (`AudioPlaybackCenter.swift:490-509` vs `548-560`): `sessionToken = UUID()`,
  `isPumping = false`, `scheduledNotYetPlayedCount = 0`, `pendingMarkerQueue
  = []`, `markerCursor = 0`, `renderedDurationSoFar = 0`,
  `wordsRenderedSoFar = 0`, then the `renderCursor`/`sessionStartWordsSkipped`/
  `elapsedBaselineAtResume`/`scheduledContentTimeCursor`/`lastKnownWordIndex`
  derivation from a target word index. The ~11 fields being reset together
  are effectively an unnamed "render-session cursor" sub-state that exists
  only as loose stored properties (lines 240-282) — a clear extraction seam
  (e.g. a small `RenderSessionCursor` struct with a
  `reset(atWordIndex:blockStarts:)` factory), not a functional change.
- **The `avgSecPerWord` estimate is computed with the identical expression
  three times**: `currentSnapshot` (lines 200-201), `skip(bySeconds:)` (lines
  455-456), `currentSeekBaseWordIndex()` (lines 581-582) — all three are
  `wordsRenderedSoFar > 0 ? (renderedDurationSoFar / Double(wordsRenderedSoFar))
  : Self.defaultSecondsPerWord`. A private computed property would remove
  the triplication.
- **Whitespace-delimited word counting is implemented four separate times**
  with the exact same one-liner `text.split(whereSeparator: {
  $0.isWhitespace }).count`: `AudioPlaybackWordIndexing.wordCount(in:)`
  (line 30), `AudioTrimHeuristics.wordCount(text:)` (line 179),
  `AudioScript.init(passthrough:)` inline (line 79), and — in a *different
  module* — `AudioWordEventTokenMapping.blockTokenStarts`
  (`LunaLibraries/Sources/LunaReaderUI/ReaderAudioLauncher.swift:108`). The
  cross-module duplication exists because `AudioWordIndexing` is declared
  `enum AudioWordIndexing` with no `public` modifier
  (`AudioPlaybackWordIndexing.swift:26`) — `LunaReaderUI` already `import
  LunaAudioPlayback` (confirmed: `ReaderAudioLauncher.swift` imports it), so
  making `AudioWordIndexing` public would let
  `AudioWordEventTokenMapping.tokenIndex`
  (`ReaderAudioLauncher.swift:120-137`) reuse
  `AudioWordIndexing.wordStartUTF16Offsets`/`wordOffset` instead of
  re-implementing the same UTF-16 word-boundary scan a second time
  (`ReaderAudioLauncher.swift:126-136` vs
  `AudioPlaybackWordIndexing.swift:61-72`) — same algorithm, same intent
  ("map a UTF-16 location to a word ordinal"), independently written twice.
- **Directory-join-for-thumbnail is duplicated**: `NowPlayingCoordinator`'s
  default `artworkFileURL` closure —
  `ReadingListStore.shared.articlesDirectory.appendingPathComponent(fileName)`
  (`NowPlayingCoordinator.swift:90`) — and
  `MiniPlayerHostViewController.thumbnailPath(fileName:)` —
  `ReadingListStore.shared.articlesDirectory.appendingPathComponent(fileName).path`
  (`MiniPlayerHostViewController.swift:244-245`) — are the same join, one
  returning a `URL` and the other a `String` path.
- **Two independent decoded-thumbnail caches exist for the same underlying
  files**: `AudioMiniPlayerView.decodedThumbnails` (an `NSCache` keyed by
  path, `countLimit = 8`, lines 87-91) and `NowPlayingCoordinator.cachedArtwork`
  (a single-slot `(fileName, artwork)` tuple, line 83). Both wrap
  `ImageDownsampling.decode` around the same article thumbnail files for the
  same currently-playing item, from two different subsystems, with two
  different caching strategies. Not fully duplicated logic (different
  consumer needs — `MPMediaItemArtwork`'s lazy system-driven request handler
  vs. a plain `UIImageView`), but a related-and-disjoint pair worth being
  aware of if either is touched.
- **Title-fallback (`item.title ?? content.title`) is written twice** in
  `AudioPlaybackCenter`: `beginPlayback` (line 515) and
  `restorableHandoffIfAvailable` (line 407, as `item.title ?? content.title`
  inside a slightly larger `position.title.isEmpty ? (...) : position.title`
  expression). A `private static func displayTitle(item:content:)` helper
  would remove the small duplication.
- **Progress/refresh cadence lives in three unrelated magic numbers**:
  `AudioPlaybackCenter`'s `progressTimer` ticks every `0.2`s (line 816),
  `positionPersistTimer` every `5`s (line 828), and
  `NowPlayingCoordinator.lastPeriodicPush` throttles pushes to `>= 0.9`s
  (line 261) — three independently-chosen cadences for what is ultimately
  the same "how often does UI/system state refresh" concern, each declared
  as a bare literal at its own call site rather than a named, documented
  constant alongside `AudioPlaybackCenter.handoffRecencyWindow`'s treatment
  (which *is* a named `public static let`, line 155). Not a bug — just
  disjoint, ad hoc timing constants that a future change could trip over.
- **Rate-step convention is duplicated by convention, not by code, across
  modules**: `AudioSettings.rateSteps` (line 26) is manually kept identical
  to the legacy `LunaReaderUI.SpeechController.cycleRate`'s menu (per this
  module's own comment, lines 22-25) — a human-maintained invariant across a
  module boundary, out of scope to fix here (the legacy path is intentionally
  being decommissioned per `claudedocs/audio-playback.md`), but worth noting
  as a fragile cross-module coupling if `SpeechController` and this module
  are ever touched in the same change.

### 2.4 Overly complex code — `AudioPlaybackCenter.swift` region map

874 lines, one `final class`. Regions (by `// MARK:`):

1. **Public state / snapshot** (lines 157-217) — `state`/`currentItemInfo`
   `didSet` observer plumbing, `currentSnapshot` computed property (a
   nontrivial estimator: total words, avg sec/word, remaining words,
   duration, elapsed, fraction — all derived live from 6 stored counters).
2. **Dependencies (seams)** (219-234) — clean, five injected protocols.
3. **Observers** (228-334, overlaps §1 physically) — standard weak-boxed
   multicast, no issues.
4. **Public controls** (336-479) — `play`/`togglePlayPause`/`pause`/`resume`/
   `restorePersistedSessionIfAvailable`/`restorableHandoffIfAvailable`/
   `pauseInternal`/skip family/`cycleRate`/`setRate`. Reasonably sized
   individually; `restorableHandoffIfAvailable` (396-411) is a pure peek and
   the easiest of the group to reason about in isolation.
5. **Playback session lifecycle** (481-586) — `beginPlayback`/
   `restartPlayback`/`currentSeekBaseWordIndex`. **Highest-value extraction
   target** — see §2.3's session-reset-block and `avgSecPerWord` findings;
   this region is where both live.
6. **Render/schedule pipeline** (588-670) — `pumpRenderingIfNeeded`/
   `handleRendered`/`scheduleRendered`. Correctly single-purposed per method;
   the `Task { … DispatchQueue.main.async { guard token == self.sessionToken
   … } }` pattern repeats 4 times across this file (here, and again 3× in
   the autoplay chain below) — a textually consistent, well-documented
   pattern (line 674's "NOTE on the `token` guards" comment covers all four
   uses at once), not accidental duplication; flagged only as a candidate if
   a future change ever wants one helper (e.g. `runGuardedAgainstNewerSession
   (_:)`) rather than four inlined `guard token == self.sessionToken`
   sites.
7. **Autoplay chain** (672-774) — `handleArticleBodyFinished`/
   `playTransitionChime`/`playAnnouncement`/`playFinalChimeThenIdle`/
   `transitionToIdle`. This is the most stateful, most nested region (three
   levels of chime→announcement→chime callback nesting in
   `playAnnouncement`, lines 715-748) but it is exactly the region
   `claudedocs/audio-playback.md`'s "autoplay chain" paragraph documents
   end-to-end, and it's the most heavily unit-tested region in
   `AudioPlaybackCenterTests`. A plausible extraction seam (not proposed as
   a change here) would be a dedicated `AudioAutoplayChain` type the center
   delegates to, mirroring how trimming was already pulled out into
   `AudioScriptPipeline`.
8. **External pause/resume** (776-786) — two one-line forwarding methods,
   no issue.
9. **Persistence** (788-810) — two small, clearly-commented methods
   (`persistPositionToAppGroup` vs `mirrorWordIndexToStore`, with an explicit
   comment on each about *why* they're separate — cheap/frequent vs.
   once-per-boundary). No issue.
10. **Timers** (812-836) — four short start/stop pairs, no issue.
11. **`tickProgress`/`wordIndex`** (838-867) — the per-200ms marker-queue
    drain + observer fan-out. Reasonably sized.
12. **State helper** (869-874) — trivial.

No redundant state machines were found: `state` (the public
`AudioPlaybackState`) and `stateBeforePause` (which state to restore to on
resume, since `.paused(itemID)` alone can't distinguish "was playing" from
"was announcing") are complementary, not duplicative — `stateBeforePause` is
read exactly once (`resume()`, line 363) and cleared on every path that makes
it stale (`beginPlayback` line 512, `transitionToIdle` line 767). `isPumping`
and `sessionToken` serve genuinely different purposes (serializing the
one-render-at-a-time renderer vs. detecting a superseded session) and are not
redundant with each other.

### 2.5 Dead/unused code

Every claim below was verified with a repo-wide grep (excluding the stray
`.claude/worktrees/` duplicate checkout and the symbol's own declaration/doc
comments).

- **`ArticleAudioEngine.stop()` / `ArticleAudioEngineControlling.stop()` is
  never called in production.** Grep: `grep -rn "\.stop()"
  LunaLibraries/Sources/LunaAudioPlayback Luna` → the only hits inside
  `ArticleAudioEngine.swift` are the method's own definition (line 132-136)
  and `deinit`'s `engine.stop()` (line 120), which calls `AVAudioEngine.stop()`
  on the *private* `engine` property (a different `stop()`, unrelated
  method), not the public API. `AudioPlaybackCenter` uses `pause()` and
  `resetAndSchedule(from:)` exclusively for its transport/seek needs — it
  never calls `stop()`. The only other reference is the test fake's own
  stub implementation (`AudioPlaybackTestFakes.swift:73`, `func stop() {
  isPlaying = false }`), which is itself never invoked by any test
  (`grep -n "\.stop()" LunaTests/ArticleAudioEngineTests.swift` → no
  matches). This is a real, unreachable public API surface — worth deciding
  whether to keep (future seek-to-zero/teardown use) or remove.
- **`AudioScriptStore.remove(forContentFileName:)` has no production call
  site.** Grep: `grep -rn "\.remove(forContentFileName" .` (excluding the
  worktree duplicate) → the only hit is `AudioScriptStoreTests.swift:93`,
  which exercises the method directly as a unit test of the store's own API.
  Nothing in `ReadingListStore`'s delete path (which the doc comment on
  `AudioScriptStore` at lines 33-41 explicitly discusses — "a stale sibling
  script would just fail to load next time") calls it; deletion is handled
  passively (an orphaned sibling file is simply never looked up again, per
  that same comment), so `remove` is dead by design, not by omission — but
  it's still unreachable from any real code path today.
- **`AudioPlaybackHandoff.wordIndex` and `.elapsed` are populated but never
  read outside tests.** `MiniPlayerHostViewController.showHandoffPreviewIfAvailable()`
  (lines 256-266) only reads `handoff.title`, `.thumbnailFileName`, and
  `.progressFraction`; `.wordIndex`/`.elapsed` are asserted directly by
  `AudioPlaybackHandoffTests` (e.g. lines 140-154) but have no production
  consumer. This is a softer case than the two above — the struct is public,
  documented, and tested as a unit, so it may simply be complete-by-design
  API rather than dead code; flagged for awareness only.
- **No other unused public symbol was found.** Every other public
  type/method in the 20 module files plus the 2 MiniPlayer files has at
  least one production (non-test) call site — confirmed individually via
  grep for: `AudioPlaybackCenter.*` public methods, `NowPlayingCoordinator`,
  `AudioSettings.*`, `AudioScriptPipeline`, `ExtensionAudioScriptResolver`/
  `Writer`, `AudioTrimModelSessionFactory`, `AudioVoiceResolution`,
  `ToneLibrary`, `AudioFormatConversion`, `ReaderAudioLauncher`,
  `AudioMiniPlayerMeld`, `AudioWordEventTokenMapping`,
  `MiniPlayerHostViewController`, `AudioMiniPlayerView`.

### 2.6 Comment hygiene

The module carries **43 "Phase N" references** across 17 of the 22 files
(counted via `grep -c "Phase [0-9]"`) — a holdover from the feature's
5-plan-doc development history. `claudedocs/audio-playback.md` itself says
up front "this doc describes what exists now, not the phase history"; the
source comments don't consistently follow that same discipline yet. Most are
harmless provenance notes, but three are genuinely **stale narration that
describes something as future/pending when it has already landed**:

- **`NowPlayingCoordinator.swift:42-55`** — the "LEGACY-CONFLICT HANDOFF"
  comment's guard #2 reads: *"Nothing in-app starts the new center while a
  legacy session is audible in Phase 2 (the center has no UI yet); Phase 3
  completes the handoff by rerouting the readers' footers off
  `SpeechController` in-app."* This describes a Phase-2-era state (no UI,
  Phase 3 not yet done). Phase 3 has landed: `ReaderAudioLauncher.center` is
  installed at launch (`Luna/AudioPlaybackWiring.swift:36`), and both
  `RSVPViewController` and `ScrollReaderViewController` route read-aloud
  through it in-app whenever it's non-nil (confirmed by grep — both files
  reference `ReaderAudioLauncher`). Guard #1 (targets re-asserted on every
  non-idle transition) is still live and correctly described; guard #2's
  phrasing is not. **Rewrite:**
  > 2. In-app, the shared readers route through `ReaderAudioLauncher.center`
  >    (installed by `AudioPlaybackWiring.install()`) whenever it's non-nil,
  >    so `SpeechController`'s conflicting Now-Playing/remote-command code is
  >    only ever reachable in-app if that install never ran — it isn't, in
  >    Luna Reader. The legacy path in practice only runs in the Share/Action
  >    extensions, which never touch `AudioPlaybackCenter` at all.
- **`AudioScript.swift:8-18`** (the type's header doc) — *"Phase 1 ships only
  the pass-through factory below... Phase 4 adds the real heuristic +
  optional on-device-LLM trimming pass... nothing else about this type needs
  to change **when that lands**."* Phase 4 has landed in this same module
  (`AudioTrimHeuristics`/`AudioTrimIntelligence`/`AudioScriptPipeline` all
  exist and are wired). A reader encountering this file today is told
  trimming doesn't exist yet. **Rewrite:**
  > A script is built once per article and cached (`AudioScriptStore`/
  > `AudioScriptPipeline`) rather than recomputed on every play. The
  > pass-through factory below (`passthroughBuilderVersion`) is the
  > trimming-disabled fallback; `AudioTrimHeuristics`/`AudioTrimIntelligence`
  > narrow `spokenBlocks` to a subset of blocks (by `blockIndex`) with
  > unedited `text` — nothing else about this type needs to change for that.
- **`AudioSettings.swift:12-13`** — *"Read by `AudioPlaybackCenter` (autoplay
  chain, rate) and, once Phase 4 lands, the trimming pipeline
  (`isIntelligentTrimmingEnabled`)."* Phase 4 has landed;
  `AudioScriptPipeline.kickOffRefinementIfEligible` (line 174) and
  `ExtensionAudioScriptResolver.kickOffOpportunisticRefinement` (line 104)
  both already read this property today. **Rewrite:**
  > Read by `AudioPlaybackCenter` (autoplay chain, rate) and by
  > `AudioScriptPipeline`/`ExtensionAudioScriptResolver`
  > (`isIntelligentTrimmingEnabled`).

The remaining ~40 "Phase N" mentions (e.g. throughout `AudioTrimHeuristics.swift`,
`ArticleAudioEngine.swift`, `AudioPlaybackCenter.swift`'s seam doc comments)
are accurate present-tense architectural cross-references that happen to be
phase-tagged (e.g. "Phase 4 seam" as a stable *name* for
`scriptProvider`/`scriptPrefetchHandler`, not a claim about pending work) —
they don't mislead a reader today and are not called out individually. If
this module is touched again for an unrelated reason, a low-priority pass
to drop the phase numbers in favor of the feature names they're now
synonymous with (heuristic trimming, LLM refinement, extension handoff, …)
would bring the source in line with the plan doc's own stated policy — but
it's cosmetic, not urgent.

No other "no longer"/"previously"/"we now"/"rather than" hits (full list
grepped) describe stale behavior — the rest are all live design-rationale
comments explaining a still-current decision (e.g. `AudioFormatConversion.swift:44-48`'s
`.endOfStream` vs `.noDataNow` explanation, `ArticleAudioEngine.swift:164-166`'s
`.dataRendered` vs `.dataPlayedBack` explanation) and were left as-is.

### 2.7 Animation structure (mini player)

`MiniPlayerHostViewController.applyBarMode(_:animated:)`
(lines 162-210) is the single point that drives all bar-visibility
animation:

- **Hidden → visible** and **visible → hidden** are two independent branches
  inside one `switch newMode`, each computing `targetFrame` once up front
  (line 163) before the switch. The hide branch (176-188) fades + translates
  down 12pt over 0.25s, then only actually sets `isHidden = true` inside the
  completion block **and only if `barMode` is still `.hidden`** (line 184) —
  a guard against a newer call re-showing the bar mid-fade-out, correctly
  preventing a race where a fast pause→play would otherwise leave the bar
  permanently hidden under an in-flight animation.
- **First appearance** (`wasHidden || miniPlayer.isHidden`, lines 191-202)
  uses a spring (`damping: 0.85`, `initialSpringVelocity: 0.3`) sliding up
  from a 16pt-lower starting transform, distinct from **subsequent
  full↔slim/frame-only updates** (204-208), which use a plain 0.25s ease
  with no transform, just a frame change. This mirrors the RSVP-meld dock
  transition (full ↔ slim) and the ordinary show/hide transition with two
  different animation curves, which is a deliberate two-tier design
  (first-appearance spring vs. steady-state reflow), not an inconsistency.
- **`AudioMiniPlayerView.setMode(_:)`** (lines 203-213) toggles
  `thumbnailView`/`skipBackButton`/`playPauseButton`/`skipForwardButton`/
  `rateButton`'s `isHidden` and the row-height constraint's `constant`
  synchronously — it is called from inside the same animation block as the
  frame change (`MiniPlayerHostViewController.swift:190`), so the row-height
  constraint change animates smoothly, but the five buttons' `isHidden`
  flips are an instantaneous cut coincident with (not eased alongside) the
  frame/height animation. This is a minor structural observation, not
  flagged as a bug — full↔slim is a rare transition (only triggered by the
  RSVP meld) and no test asserts cross-fade behavior for it.
- Progress-bar animation is separate and simpler: `setProgress(_:animated:)`
  (`AudioMiniPlayerView.swift:235-237`) forwards straight to
  `MoonHorizonProgressBar.setProgress`, driven every ~200ms by
  `AudioPlaybackCenter`'s progress ticks via
  `MiniPlayerHostViewController`'s `didUpdateProgress` observer callback
  (`MiniPlayerHostViewController.swift:342-352`), which also
  opportunistically re-validates the meld anchor on every tick (documented
  as intentional — the RabbitHole host can show/hide the RSVP anchor without
  any callback).

---

## 3. Test coverage note

Direct 1:1 test files exist for the great majority of the module:

| Source file | Test file |
|---|---|
| `ArticleAudioEngine.swift` | `ArticleAudioEngineTests.swift` (environment-fragile — see below) |
| `AudioFormatConversion.swift` | `AudioFormatConversionTests.swift` |
| `AudioPlaybackCenter.swift` | `AudioPlaybackCenterTests.swift`, `AudioPlaybackHandoffTests.swift` |
| `AudioPlaybackPositionStore.swift` | `AudioPlaybackPersistenceTests.swift` |
| `AudioPlaybackWordIndexing.swift` | `AudioWordIndexingTests.swift` |
| `AudioScript.swift` | `AudioScriptTests.swift` |
| `AudioScriptPipeline.swift` | `AudioScriptPipelineTests.swift` |
| `AudioScriptStore.swift` | `AudioScriptStoreTests.swift` |
| `AudioSessionCoordinator.swift` | `AudioSessionCoordinatorTests.swift` |
| `AudioTrimHeuristics.swift` | `AudioTrimHeuristicsTests.swift` |
| `AudioTrimIntelligence.swift` | `AudioTrimIntelligenceTests.swift` |
| `ExtensionAudioScriptResolver.swift` | `ExtensionAudioScriptResolverTests.swift` |
| `ExtensionAudioScriptWriter.swift` | `ExtensionAudioScriptWriterTests.swift` |
| `NowPlayingCoordinator.swift` | `NowPlayingCoordinatorTests.swift` |
| `SpeechRenderer.swift` | `SpeechRendererSpikeTests.swift` (targeted spike, not full coverage) |
| `ToneLibrary.swift` | `ToneAssetTests.swift` |
| `AudioMiniPlayerView.swift` (pure `barMode`/`Display`) | `AudioMiniPlayerTests.swift` |
| `MiniPlayerHostViewController.swift` (pure `MiniPlayerNavigation` only) | `AudioMiniPlayerTests.swift` |

**Gaps:**
- **`AudioTrimModelSessionFactory.swift` and `AudioVoiceResolution.swift`
  have no dedicated test file.** `AudioTrimModelSessionFactory.makeDefault()`'s
  `#available` branch selection is never asserted directly (tests always
  inject a `FakeTrimModelSession` instead of exercising the factory).
  `AudioVoiceResolution.resolveBestVoice()` is exercised only indirectly
  through `SpeechRendererSpikeTests`, which is itself a targeted spike test,
  not a `AudioVoiceResolution`-focused suite. Both are small/simple enough
  that this is low-risk, but it is a real gap.
- **`MiniPlayerHostViewController` itself has no direct test** — only its
  extracted pure logic (`MiniPlayerNavigation.stackIndex`,
  `AudioMiniPlayerView.barMode`) is asserted. The view controller's own
  instance behavior (`showHandoffPreviewIfAvailable`, `handlePlayPauseTap`,
  `applyBarMode`'s animation-state bookkeeping, `refreshDisplay`) is
  untested — consistent with the boundary-violation note in §2.2 (no seam
  exists to substitute `AudioPlaybackCenter.shared`/`AudioSettings`/
  `ReadingListStore.shared` for a fake in a test).
- **`ArticleAudioEngineTests` is environment-fragile per `CLAUDE.md`**: it
  needs a real `AVAudioEngine.start()` even in manual/offline-rendering mode,
  and has reproducibly aborted the whole test host with a mediaserverd "RPC
  timeout, apparently deadlocked" on at least one Mac. **Any refactor
  touching `ArticleAudioEngine.swift` must keep its public API
  (`format`/`rate`/`lowWaterMark`/`needsMoreAudioHandler`/`isPlaying`/
  `currentTime`/`play`/`pause`/`stop`/`resetAndSchedule`/`schedule`/
  `scheduleTone`/`renderOffline`) stable enough that this suite's existing
  assertions keep compiling** even if it can't be run to green on every
  machine — per `CLAUDE.md`'s documented workaround
  (`-skip-testing:LunaTests/ArticleAudioEngineTests`, verify separately).

## 3b. Doc drift — `claudedocs/audio-playback.md`

The doc is, overall, current and accurate against the code — every
architectural claim spot-checked (word-event contract, autoplay chain order,
`AudioSettings` defaults/keys, `AudioSessionCoordinator` interruption/route-
change policy, `NowPlayingCoordinator` skip intervals (30/15s), Phase 6
extension-handoff mechanics, `handoffRecencyWindow` = 30 min, the legacy-
conflict re-assertion rule) matches the code exactly. Two drifts found:

- **Phase count is internally inconsistent.** The doc's opening line says
  *"Landed in 5 phases (engine core; playback center + system integration;
  UI; trimming; final integration merge)"* — but the same doc later has
  dedicated `### Extension audio (Phase 6)` (line 156) and `## Siri (Phase
  7)` (line 402) sections, i.e. the feature actually landed in (at least) 7
  phases, not 5. The intro line was never updated when Phases 6/7 were
  added. Low-impact (doesn't mislead about current behavior, only about
  history), but a one-line fix (`"Landed in 7 phases"` or drop the phase
  count from the intro sentence entirely) would remove the inconsistency.
- **The "Key file paths" test-file list uses a name that doesn't match any
  actual file.** Line 314-318 lists
  `LunaTests/{...,MiniPlayer,...}Tests.swift`, implying a file named
  `MiniPlayerTests.swift`; the actual (and only) file covering this area is
  `AudioMiniPlayerTests.swift`. Minor — the list is explicitly abbreviated
  with `...`, but the one name given is wrong rather than merely
  incomplete.

No other drift found; the doc's `AudioSettings`/`NowPlayingCoordinator`/
`AudioSessionCoordinator`/trimming-pipeline sections all read as if written
by someone who had just re-read the current source, unlike the three stale
source comments in §2.6.

---

## Top 10 highest-value changes (ranked)

1. **[M]** Extract the `beginPlayback`/`restartPlayback` shared session-reset
   block (§2.3, §2.4 region 5) into one private helper or a small
   `RenderSessionCursor` value — removes the largest exact-duplicate block in
   the module and gives the ~11 loose stored properties it resets a name.
2. **[S]** De-duplicate the `avgSecPerWord` expression into one private
   computed property (§2.3) — three verbatim copies, zero risk to extract.
3. **[S]** Rewrite the three stale "Phase N lands"/"Phase 3 completes the
   handoff" comments in `NowPlayingCoordinator.swift:42-55`,
   `AudioScript.swift:8-18`, `AudioSettings.swift:12-13` (§2.6) — concrete
   rewrites given above; these are the only comments in the module that
   actively mislead a new reader about whether a feature exists.
4. **[S]** Decide the fate of `ArticleAudioEngine.stop()`/
   `ArticleAudioEngineControlling.stop()` (§2.5) — confirmed dead in
   production; either remove (protocol + concrete + fake) or document why it
   must stay for a future caller.
5. **[S]** Decide the fate of `AudioScriptStore.remove(forContentFileName:)`
   (§2.5) — confirmed reachable only from its own test.
6. **[M]** Make `AudioWordIndexing` `public` and have
   `AudioWordEventTokenMapping` (`ReaderAudioLauncher.swift`, `LunaReaderUI`)
   reuse `wordStartUTF16Offsets`/`wordOffset` instead of re-implementing the
   same UTF-16 word-boundary scan a second time in a different module
   (§2.3) — real cross-module duplication with a straightforward fix (module
   already imports `LunaAudioPlayback`).
7. **[S]** Give `MiniPlayerHostViewController`'s autoplay toggle the same
   center-brokered treatment its rate control already gets (§2.2) — add a
   symmetric `AudioPlaybackCenter.toggleAutoplay()`/wrap
   `AudioSettings.isAutoplayEnabled` behind the center the way `rate`/
   `preferredRate` already is, removing the one direct `AudioSettings` write
   from the view-controller layer.
8. **[S]** Consolidate the `NowPlayingCoordinator`/`MiniPlayerHostViewController`
   thumbnail-directory-join one-liner into a single shared helper (§2.3) —
   trivial, low-risk.
9. **[S]** Add a focused test file (or fold into an existing one) for
   `AudioTrimModelSessionFactory.makeDefault()`'s `#available` branch, and
   for `AudioVoiceResolution.resolveBestVoice()`'s simulator/non-simulator
   branches (§3) — closes the two files with no dedicated coverage.
10. **[L]** Consider extracting `AudioPlaybackCenter`'s "Autoplay chain"
    region (§2.4, region 7 — `handleArticleBodyFinished`/
    `playTransitionChime`/`playAnnouncement`/`playFinalChimeThenIdle`/
    `transitionToIdle`, ~100 lines with 3-deep callback nesting) into its own
    type, mirroring how trimming was already pulled into
    `AudioScriptPipeline` — the single largest, most-nested region of the
    874-line file, though also its most heavily-tested, so this is a larger,
    lower-urgency structural change than items 1-9.
