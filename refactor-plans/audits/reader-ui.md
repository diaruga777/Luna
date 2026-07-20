# Reader UI audit — LunaReaderUI / LunaArchiveReader / LunaReaderEngine / LunaEpub / LunaDocuments / LunaContentRendering

Read-only audit. No code changed. Scope: all 28 files in `LunaLibraries/Sources/LunaReaderUI/`, all 5
files in `LunaLibraries/Sources/LunaArchiveReader/`, all 4 files in `LunaLibraries/Sources/LunaReaderEngine/`,
both files in `LunaLibraries/Sources/LunaEpub/`, the 1 file in `LunaLibraries/Sources/LunaDocuments/`, and
`LunaLibraries/Sources/LunaContentRendering/`. Every file was read in full (line-count-verified). Findings
already fixed or explicitly deferred in `CODE_REVIEW_PLAN.md` / `PERF_REVIEW_PLAN.md` are excluded.

Method: this audit was produced by 7 parallel deep-reads (RSVPViewController; ScrollReaderViewController;
the rabbit-hole cluster; the web/split-overlay cluster; the inline-reader-host cluster; the speech/audio/
support-file cluster; the archive-support+engine+epub+documents cluster), each grep-verifying every claim
against the real source tree (excluding `build/`, `.claude/worktrees/`, `.git`, DerivedData, and sibling
worktree checkouts outside `/Users/hsp/Desktop/Luna`), then synthesized here with cross-cluster
reconciliation.

## 0. `LunaContentRendering` — confirmed dead, undeclared module

On `main` (verified directly, not delegated): `LunaLibraries/Sources/LunaContentRendering/` contains only
an **empty** `DotMatrix/` subdirectory — zero source files — and the module is **not declared anywhere in
`LunaLibraries/Package.swift`**: no `.target(name: "LunaContentRendering")`, no `.library`, no dependency
edge from any other target.

```
find LunaLibraries/Sources/LunaContentRendering -type f          → (no output)
grep -n "LunaContentRendering" LunaLibraries/Package.swift        → (no match)
```

There is a *populated* version of this module (a Metal pixel-mosaic transition engine backing
`LunaTransitions`' "DotMatrix" effects, plus `RabbitHoleTransitionView.swift`) sitting in a **separate,
unmerged worktree** (`.claude/worktrees/agent-a44f9578d823e01c8/`, branch `worktree-agent-a44f9578d823e01c8`)
— that is unrelated in-progress work by another agent on a different branch, not part of `main`, and out
of scope for this audit. On `main`, the module is fully vestigial: nothing to migrate, nothing to update —
the recommended action is simply to delete the empty `DotMatrix/` directory (or leave it; it costs nothing
to build since it isn't a package target at all).

---

## 1. Structure map

### LunaReaderUI (28 files)

| File | Lines | Responsibility | Public API (key members) | Used by (file:line, grep-verified) |
|---|---|---|---|---|
| `RSVPViewController.swift` | 1542 | Word/phrase-by-phrase RSVP speed reader: display, scrub, skip, WPM, link pill, read-aloud (legacy `AVSpeechSynthesizer` + `AudioPlaybackCenter`) | `onFinishedReading`, `onMovedAwayFromEnd`, `onLinkActivated`, `onLinkActivatedAtPoint`, `onPlaybackStateChanged`, `topContentInset`, `isPlaying`, `currentReadingWordIndex`, `init`, `configureForReuse` | `ReaderViewController.swift:377-384`, `InlineReaderPageViewController.swift:329-337`, `RabbitHoleLayerViewController.swift:82,216,303,690-720,816,840`, `Luna/Reader/ArticleCardsViewController.swift:983-988,1038-1045` (recursive `children` walk); `LunaTests/ReaderScreenTests.swift`, `RSVPAudioResyncTests.swift` |
| `ScrollReaderViewController.swift` | 1510 | Scrolling article reader: `UITextView` render, chrome inset, image tap/lightbox, sentence-selection share, link taps → split overlay, read-aloud, scroll-position persistence | `onFinishedReading`, `onMovedAwayFromEnd`, `onLinkActivated`, `onLinkActivatedWithRange`, `onShareFooterVisibilityChanged`, `linkActivationPoint(forCharacterRange:)`, `topChromeInset`, `currentReadingWordIndex`/`currentReadingScrollOffsetY`, `prepareFullContent()`, `activateVisibleReader(...)`, `makeHighlightShareText(...)` | `ReaderViewController.swift:410-421`, `RabbitHoleLayerViewController.swift:81,214,692-707,787,837-840`, `InlineReaderPageViewController.swift:314-357`; `LunaTests/ReaderScreenTests.swift`, `HighlightShareTextTests.swift`, `ArticleTextRendererProgressiveTests.swift` |
| `LinkRSVPPreview.swift` | 1129 | Long-press-on-a-link floating RSVP preview card: gesture policy, async article load, mini word-timer playback engine, drag-up action menu | `LinkRSVPPreviewGesturePolicy` (pure), `ArticleRSVPPreviewSession`, `LinkRSVPPreviewInteraction` (internal), `LinkRSVPPreviewViewController` (private) | `ArticleRSVPPreviewSession` → `ArticleCardsViewController.swift:74,688`; `LinkRSVPPreviewInteraction` → `ScrollReaderViewController.swift:141,465`, `RSVPViewController.swift:167,694`; policy pure-fns → `LunaTests/LinkRSVPPreviewGesturePolicyTests.swift` |
| `RabbitHoleLayerViewController.swift` | 882 | One stacked card/layer: URL article-probe, embeds shared scroll/RSVP/original readers or a `WKWebView`, own chrome (pills/lips) | `onLinkActivated`, `onLinkActivatedAtPoint`, `onPopToHere`, `onBecameArticle`, `onModeChanged`, `onBack`, `readerMode`, `isArticle`, `init`, `configure`, `applyDepth`, `setChrome`, `setMode`, `performSave`/`performShare`, `syncReadingPosition`, `lineText(for:)` | constructed only at `RabbitHoleReaderViewController.swift:233`; 2 direct test constructions `LunaTests/RabbitHoleStackStoreTests.swift:21,40` |
| `RabbitHoleReaderViewController.swift` | 555 | The persistent card stack: dive/pop, per-save trail persistence (`RabbitHoleStackStore`), `ReaderChromeControlling`/`ReaderChromeState` for the external host | `ReaderChromeState`, `ReaderChromeControlling` (protocol), `init`, `containsReaderItem`, `onContentHierarchyChanged`, `onRootBack`, `rootItemID` (dead, §2.5), `chromeState`/`chromeSetMode`/`chromeToggleAudio`/`chromeSave`/`chromeShare`/`chromeBack` | constructed only at `ReaderHostFactory.swift:20`; consumed by `Luna/Reader/ArticleCardsViewController.swift` (extensive), `Luna/MiniPlayer/MiniPlayerHostViewController.swift:364` (`ReaderItemContaining`) |
| `SplitWebOverlayViewController.swift` | 825 | Nested "eclipse" split-web reader with a growing tab strip, presented over another reader's fixed chrome | `InlineReaderPresentationCoordinating` (protocol), stored closures `onDismiss`/`onDismissalTransitionWillBegin`/`onDismissalTransitionDidCancel`/`onOpen`/`onClose`(dead)/`onChromeStateChanged`, `init`, `ReaderChromeControlling` conformance incl. dead `chromeSave` | constructed at `Luna/UITestScreen.swift:124`, `RSVPViewController.swift:651`, `ScrollReaderViewController.swift:1356`, `RabbitHoleReaderViewController.swift:316`, 2× `LunaTests/InlineReaderTabMetricsTests.swift`; `InlineReaderPresentationCoordinating` implemented by `ArticleCardsViewController.swift`, `RabbitHoleReaderViewController.swift`, `ReaderViewController.swift`, `RSVPViewController.swift` |
| `ReaderViewController.swift` | 447 | Top-level mode-switchable reader (scroll/RSVP/original) with its own nav-bar-or-inline chrome + floating share button; the stable `InlineReaderPresentationCoordinating` for a nested split overlay | `init`, `inlineReaderWillPresent/DidDismiss` + geometry getters, `onModeChange` | `Luna/CatchUp/CatchUpViewController.swift:338`, `Luna/UITestScreen.swift:112,178`, `LunaShareSurface/ShareReaderViewController.swift:159`, `LunaReaderClip/ClipReaderViewController.swift:69`; 7 sites in `LunaTests/ReaderScreenTests.swift` |
| `InlineReaderPageViewController.swift` | 382 | One page inside `SplitWebOverlayViewController`'s inner nav stack: WKWebView load, off-main article probe, mode-switch embed | `url`, `onLinkActivated`(dead)/`onLinkActivatedAtPoint`/`onBecameArticle`/`onMetadataChanged`/`onContentScrollViewChanged`, `isArticle`, `setMode`, `toggleAudio` | sole constructor: `SplitWebOverlayViewController.swift:229` (`makePage`) |
| `InlineReaderEclipseTransition.swift` | 369 | The canonical "eclipse" transition: geometry structs (`InlineReaderPresentationMetrics`, `InlineReaderTabMetrics`) + `InlineReaderEclipseScene`/`InlineReaderEclipseAnimator` | (all public, see above) | used exclusively by `SplitWebOverlayViewController.swift` (4 animator constructions: 190,204,268,282; metrics: 456,523-526) |
| `InlineReaderContentLoader.swift` | 34 | Internal `enum` — resolve a link URL to native `ArticleContent` (cache → fetch → extract → image-download → cache-write) | `load(url:owner:)` (not public) | sole caller `InlineReaderPageViewController.swift:219` |
| `ReaderHostFactory.swift` | 26 | Single construction point for the full-screen `RabbitHoleReaderViewController` a save opens into | `ReaderHostFactory.make(item:content:shareProvider:fullContentUpFront:)` | `ArticleCardsViewController.swift:477,873`, `ReadingListViewController.swift:451,1421`, `MiniPlayerHostViewController.swift:318` |
| `ReaderProviders.swift` | 28 | Two cross-tier protocols: `ReaderShareProviding`, `ReaderPositionTracking` | both protocols | `ReaderShareProviding` impl. by `AppReaderShareProvider` (app shell), `ExtensionReaderShareProvider` (`LunaShareSurface`); threaded through every reader type. `ReaderPositionTracking` checked `ReaderViewController.swift:362`, implemented by Scroll+RSVP |
| `SpeechController.swift` | 335 | On-device read-aloud driver wrapping one `AVSpeechSynthesizer` — the scroll reader's legacy fallback path | `SpeechControllerDelegate` protocol, `init`, `currentWordIndex`, `play/pause/resume/togglePlayPause/skipForward/skipBackward/cycleRate/stop`, static `speakableBlocks` | constructed only `ScrollReaderViewController.swift:1022` |
| `SpeechEngine.swift` | 94 | `SpeechEngine` protocol + `SpeechEngineFactory.resolveSelected()` + `BasicSpeechEngine`/`AppleEnhancedEngine` | as above | `SpeechController.swift:36,108`, `RSVPViewController.swift:1081`, `VoiceModelStore.swift:29` |
| `SpeechVoice.swift` | 24 | `SpeechVoice.systemDefault` | 1 static | `SpeechEngine.swift:58,73` |
| `ReaderAudioLauncher.swift` | 138 | 3 unrelated enums in one file: `ReaderAudioLauncher` (center seam), `AudioMiniPlayerMeld` (mini-player anchor), `AudioWordEventTokenMapping` (pure word-index math) | `.center`, `ownsPlayback`, `pauseIfPlaying`; `didChangeNotification`/`anchorView`/`setAnchor`; `blockTokenStarts`/`tokenIndex` | `.center` set `Luna/AudioPlaybackWiring.swift:43`; read across RSVP/Scroll/RabbitHole/LinkRSVPPreview; `AudioMiniPlayerMeld` ↔ `MiniPlayerHostViewController`, RSVP:409-425; `AudioWordEventTokenMapping` → RSVP:1344,1452, `LinkRSVPPreview.swift:1029-1033`, tested `LunaTests/AudioMiniPlayerTests.swift` |
| `ReaderAudioSession.swift` | 29 | `activate()`/`deactivate()` AVAudioSession wrapper | 2 static funcs | only `SpeechController.swift:146,211,267`, `RSVPViewController.swift:432-433` |
| `VoiceFirstRunPrompt.swift` | 42 | First-run "enable enhanced voice" alert | static `openVoiceSettings` closure, `showIfNeeded(from:)` | set `Luna/AppDelegate.swift:134`; no test file |
| `VoiceModelStore.swift` | 49 | UserDefaults-backed flags: enhanced-voice-installed, seen-prompt, dismissed-catch-up | 3 get/set properties | `Settings/VoiceSettingsScreen.swift:60`, `CatchUpViewController.swift:513,663,677`, `VoiceFirstRunPrompt.swift:27-29`, `LunaReadingListUI/ReadingListSectioning.swift:199`; no direct test |
| `ArticleTextRenderer.swift` | 321 | Builds the `NSAttributedString` render (progressive prefix + full) + block/image ranges for `ScrollReaderViewController` | `RenderedArticle`, `render(_:)`/`render(_:characterBudget:)` | only `ScrollReaderViewController.swift:206-207,269-270,566,666`; `ArticleTextRendererProgressiveTests.swift` (12 call sites) |
| `WordMap.swift` | 69 | Word-range index over a `RenderedArticle` (binary search) | `WordMap(content:rendered:)`, `wordRanges`, `wordCount`, `attributedRange`, `wordIndex(nearCharacterIndex:)` | `ScrollReaderViewController.swift` (7 sites), `SpeechController.swift:101,115,323`; `WordMapTests.swift` (full coverage) |
| `ArticleImageDownloader.swift` | 237 | Downloads/dedupes/transcodes article images to the shared images dir | `download(...)` (2 overloads), `resolveLocalImages` | `InlineReaderContentLoader.swift:27`, `ArticleCoverThumbnail.swift:87`, `ScrollReaderViewController.swift:182,238,658`, `LunaReadingList/PreloadCoordinator.swift:253`, `ReadingListIngestor.swift:184-211` |
| `ArticleCoverThumbnail.swift` | 108 | Extracts/backfills a lead-image thumbnail for a saved article | `coverImageData`, `backfillThumbnail` | `ShareSurfaceDriver.swift:247`, `ReadingListIngestor.swift:213,463`; `ArticleCoverThumbnailTests.swift` |
| `ArticleShareView.swift` | 65 | End-of-article "Share" prompt view | `ArticleShareView(onShare:)` | `ScrollReaderViewController.swift:394-400`, `RSVPViewController.swift:1405-1411`; no test |
| `ImageLightboxViewController.swift` | 204 | Full-screen zoom/pan/pinch image viewer with a bespoke interactive-dismiss | `init(image:sourceFrame:)` | only `ScrollReaderViewController.swift:724`; no test |
| `RabbitHoleLayerDescriptor.swift` | 64 | `Codable` per-layer persisted state (`RabbitHoleLayerDescriptor`, `RabbitHoleStack`) | fields: `urlString`,`wordIndex`,`scrollOffset`,`originalScrollOffset`,`readerMode`,`title`,`bottomLipText`,`url` | consumed by `RabbitHoleLayerViewController.swift`/`RabbitHoleReaderViewController.swift`; `RabbitHoleStackStoreTests.swift` |
| `RabbitHoleLayout.swift` | 104 | Pure geometry: card-stack lip/indent/corner tunables, `Role`, `Placement`, `placement(...)` | `lipHeight`,`indentWidth`,`maxVisibleAncestors`,`cornerRadius`,`Role`,`Placement`,`visibleAncestors`,`cardFrame`,`placement` | consumers use only `placement(...)` (`RabbitHoleReaderViewController.swift:281`); `RabbitHoleLayoutTests.swift` |
| `RabbitHoleStackStore.swift` | 67 | Per-root-item persistence of the `RabbitHoleStack` trail | `.shared`, `init(containerURL:)`, `load`, `save`, `clear` | `RabbitHoleReaderViewController.swift:197,530,543`; `RabbitHoleStackStoreTests.swift` |

### LunaArchiveReader (5 files)

| File | Lines | Responsibility | Public API | Used by |
|---|---|---|---|---|
| `ArchiveWebReaderViewController.swift` | 1009 | Unlocks a paywalled/blocked article via archive.today (or a direct-unlock/trailing-dot pre-stage) in a real `WKWebView`, then extracts+saves | `init`, `onClose`/`onExtracted`/`onOpenInBrowser`, static `archiveURL`/`webPreStageURLs`/`decideStage`/`isJavaScriptRequiredGate` | `Luna/SceneDelegate.swift:120`, `ArticleCardsViewController.swift:498`, `ReadingListViewController.swift:1440`, `CatchUpViewController.swift:444`, `LunaShareSurface/ShareReaderViewController.swift:138`, `ShareSurfaceDriver.swift:342` |
| `OriginalPageViewController.swift` | 123 | Shows the locally captured `.webarchive` (or imported doc, or live-URL fallback) for a saved item | `init`, convenience `init(store:)`, `contentScrollView`/`currentScrollOffset`, `configure` | `ReaderViewController.swift:388`, `RabbitHoleLayerViewController.swift:217` |
| `PaywallUnlockRules.swift` | 319 | Site-rule table → `WKContentRuleList` JSON + DOM-cleanup `WKUserScript` | `urlFilters`, `contentRuleListJSON`, `compiledRuleList`, `domCleanupScript`, `cleanupUserScript` | `ArchiveWebReaderViewController.swift:202,294`; `PaywallUnlockRulesTests.swift` |
| `SiteCleanupScripts.swift` | 65 | Bundled per-site bespoke JS (`site_cleanup_scripts.json`) lookup | `script(for:)`, `userScript(for:)`, `count` | `ArchiveWebReaderViewController.swift:205`; `SiteCleanupScriptsTests.swift` |
| `WebArchiveCapturer.swift` | 93 | Headless off-screen `WKWebView` → `.webarchive` `Data` (async) | `capture(url:)`, `capture(html:baseURL:)` | `ReadingListIngestor.swift:505,507`; **no test file** |

### LunaReaderEngine (4 files, pure logic)

| File | Lines | Responsibility | Public API | Used by |
|---|---|---|---|---|
| `ChunkPlanner.swift` | 152 | Groups the RSVP word stream into timed phrases | `TextChunk`, `chunks(words:)`, `duration(for:wpm:)` | `RSVPViewController.swift:52,210,254,1188`; `ChunkPlannerTests.swift` |
| `ReadingHeuristics.swift` | 115 | Lexical heuristics (binder/phrase-starter sets, syllable estimate, difficulty) backing `ChunkPlanner` | `leadingBinders`,`phraseStarters`,`functionWords`,`core`,`isLeadingBinder`,`isPhraseStarter`,`isFunctionWord`,`hasDigit`(dead),`syllableEstimate`,`difficultyFactor` | `ChunkPlanner.swift:94,97,109,136`; `ReadingHeuristicsTests.swift` |
| `RSVPEngine.swift` | 173 | `ArticleContent` → timed `RSVPWord` stream + token↔frame index mapping | `RSVPWord`, `RSVPEngine`, `frameIndex`/`tokenIndex`, `makeWord`(over-exposed), `orpIndex`, `skipTarget`, `duration(at:)` | `RSVPViewController.swift` (extensive), `LinkRSVPPreview.swift` (same pattern); `RSVPEngineTests.swift` |
| `WordSplitter.swift` | 53 | Splits an over-long RSVP word for display | `split`, `hyphenSplit`(over-exposed), `hardWrap`(over-exposed) | `RSVPEngine.swift:47`; `WordSplitterTests.swift` |

### LunaEpub (2 files) / LunaDocuments (1 file)

| File | Lines | Responsibility | Public API | Used by |
|---|---|---|---|---|
| `EpubBuilder.swift` | 198 | Minimal single-chapter EPUB 3 (embedded images) for send-to-Kindle | `EpubBuilder`, `build`, `escapeXML` | `LunaSend/ArticleSendCoordinator.swift:259,350`, `LunaReadingList/ArticleExportService.swift:42`; `EpubBuilderTests.swift` |
| `MIMEMessage.swift` | 75 | RFC 5322 multipart/mixed email w/ base64 attachment (Kindle-send transport) | `MIMEMessage`, `messageData`, `encodedHeaderText` | `LunaSend/ArticleSendCoordinator.swift:66`; `MIMEMessageTests.swift` |
| `DocumentParser.swift` | 144 | Imported document (PDF/RTF/MD/txt) → `ArticleContent`; hosts `PlainTextParser`/`MarkdownParser` | `DocumentParser.parse`, `PlainTextParser.blocks`, `MarkdownParser.blocks` | `ReadingListIngestor.swift:355`; `DocumentParserTests.swift` |

---

## 2. Findings

### 2.1 Stored-callback communication

This is the richest theme in the audit: the reader stack is wired almost entirely through stored closure
properties rather than delegate protocols, and the same 2-6 closures are repeatedly set together, at the
same call sites, for the same single collaborator. Every cluster below is a genuine consolidation
candidate (component-boundary communication, not one-shot completions).

**Cluster 1 — `RabbitHoleLayerViewController` → `RabbitHoleReaderViewController` (6 closures, strongest candidate).**
All six are set in exactly one place, `RabbitHoleReaderViewController.makeLayer()` (lines 232-266), each
repeating the same `[weak self, weak layer] … guard let self, let layer … else { return }` boilerplate:

| Closure | Decl | Set | Invoked |
|---|---|---|---|
| `onLinkActivated` | `RabbitHoleLayerViewController.swift:36` | `RabbitHoleReaderViewController.swift:238-241` | `RabbitHoleLayerViewController.swift:702,715` |
| `onLinkActivatedAtPoint` | `:39-40` | `:242-250` | `:700,713` |
| `onPopToHere` | `:42` | `:251-255` | `:500` |
| `onBecameArticle` | `:44` | `:260` | `:640` |
| `onModeChanged` | `:46` | `:256-259` | `:545` |
| `onBack` | `:49` | `:261` | `:502` |

One `protocol RabbitHoleLayerDelegate: AnyObject` (link-activated, pop-to-here, became-article, mode-
changed, back) implemented once by `RabbitHoleReaderViewController` would remove 6 property assignments
and the repeated weak-capture guard at every construction.

**Cluster 2 — `SplitWebOverlayViewController` presentation-coordinator wiring (5 closures, 3 identical call sites).**
`onDismiss`, `onDismissalTransitionWillBegin`, `onDismissalTransitionDidCancel`, `onOpen`, `onChromeStateChanged`
(decls `SplitWebOverlayViewController.swift:49-54`) are wired **identically** at every construction site —
`RSVPViewController.swift:659-678`, `ScrollReaderViewController.swift:1362-1382`,
`RabbitHoleReaderViewController.swift:329-348` (plus a 3-closure subset in `Luna/UITestScreen.swift:133-144`)
— each simply forwarding to the matching `InlineReaderPresentationCoordinating` method on an ancestor found
by walking `parent`. All 3 real call sites also independently re-implement the same
`inlineReaderPresentationCoordinator`/`enclosingReaderViewController` "find my host" ancestor-walk (RSVP:682,
RabbitHole:352, ScrollReader:1386 — the last one keyed on the concrete `ReaderViewController` type instead of
the protocol). A single `SplitWebOverlayViewController.wireCoordinator(_:)` helper (or moving the whole
5-closure→protocol forwarding into `InlineReaderPresentationCoordinating`'s default extension) would collapse
3 duplicated ~20-line blocks into one.

**Cluster 3 — `onFinishedReading` / `onMovedAwayFromEnd` (paired everywhere, 2 reader types, 2 hosts).**
Declared identically on both `RSVPViewController.swift:31,33` and `ScrollReaderViewController.swift:21,23`;
always set together by the same two hosts:
- `ReaderViewController.swift:382-383` (RSVP), `:415-416` (Scroll)
- `RabbitHoleLayerViewController.swift:705-706` (Scroll), `:718-719` (RSVP)

This is the single strongest "same pair, multiple types, multiple hosts" pattern in the whole audit — a
shared `ReaderCompletionDelegate` (`didFinishReading`/`didMoveAwayFromEnd`) implemented by both reader types
would let every host wire one delegate instead of two closures × two reader types.

**Cluster 4 — `onLinkActivated` / `onLinkActivatedAtPoint` "point-or-plain" fallback (duplicated 4+ times, and the plain variant is dead everywhere — see §2.5).**
The identical shape —
```swift
if let onLinkActivatedAtPoint { onLinkActivatedAtPoint(url, point) } else { onLinkActivated?(url) }
```
— is independently hand-written in `RSVPViewController.swift:640-647`, `ScrollReaderViewController.swift:1185-1188`,
`InlineReaderPageViewController.swift:316-325` **and** `:332-339` (duplicated twice in the same file), and
`RabbitHoleLayerViewController.swift:695-702,710-715`. A single free helper
`forwardLinkActivation(url:point:onPoint:onPlain:)` in `LunaReaderUI` would remove all 5-6 copies at once
— and since `onLinkActivated` (the plain variant) is confirmed dead at every one of these sites, the
simplest fix is actually to delete the plain closure entirely and always carry the point (see §2.5).

**Cluster 5 — `ArchiveWebReaderViewController`'s `onClose`/`onExtracted`/`onOpenInBrowser` (3 closures, 5 near-identical presenter blocks).**
Wired at `ArticleCardsViewController.swift:501-518`, `ReadingListViewController.swift:1442-1467`,
`CatchUpViewController.swift:447-461`, `ShareSurfaceDriver.swift:343-345`, `ShareReaderViewController.swift:140-149`
— the three app-shell sites are the same ~20-line "build reader, wrap in nav controller, dismiss-on-close,
dismiss+open-in-Safari, dismiss+refetch+reopen" pattern, differing only in the reopen tail. This spans the
app-shell layer (outside `LunaReaderUI`'s ownership) but the type itself lives in `LunaArchiveReader`, so a
shared `ArchiveReaderPresenter` helper is worth flagging even though the fix lands elsewhere.

**Cluster 6 — `InlineReaderPageViewController`'s 5-closure page delegate (single collaborator, low priority).**
`onLinkActivatedAtPoint`, `onBecameArticle`, `onMetadataChanged`, `onContentScrollViewChanged` (+ dead
`onLinkActivated`) are all set once, together, by `SplitWebOverlayViewController.makePage` (lines 229-241) —
one collaborator, one set-site: lower urgency than Clusters 1-2 (no duplication across call sites) but the
same shape and could fold into one `InlineReaderPageDelegate` for symmetry.

**Cluster 7 — `RabbitHoleReaderViewController` ↔ outer card-carousel host (2 closures, notify-direction only).**
`onContentHierarchyChanged` (decl `:272`, set `ArticleCardsViewController.swift:895-899`) and `onRootBack`
(decl `:366-368`, set `:888-894`) are the *notify* half of a pairing whose *query* half is already unified as
the `ReaderChromeControlling` protocol — a natural follow-up would add a matching `RabbitHoleReaderDelegate`
implemented by the host, completing the pattern already used for the query direction.

**One-shot / injected config — explicitly NOT flagged (correctly scoped as-is):**
`ArticleShareView.onShare` (set once per instance at construction, 2 call sites), `ArticleRSVPPreviewSession`/
`LinkRSVPPreviewInteraction`'s `sourcePlaybackChanged` (1 collaborator each), `VoiceFirstRunPrompt.openVoiceSettings`
(1 set-site, app-shell seam), `ReaderViewController.onModeChange` (1 injected-config call site).

### 2.2 View/container boundary violations

The overall picture is **clean layering** — no host mutates a reader's private subviews, and no reader
directly imports/references a concrete carousel type. Every cross-tier link is closure- or protocol-mediated,
matching `CLAUDE.md`'s stated design. Two genuine exceptions and one asymmetry worth flagging:

- **`ScrollReaderViewController.openSplit` reaches past its own closure contract.** `openSplit()`
  (`ScrollReaderViewController.swift:1350`) walks `parent` via `enclosingReaderViewController` (1386-1393) to
  find a concrete `ReaderViewController` ancestor, then calls its **internal-looking** methods
  (`inlineReaderWillPresent`/`inlineReaderWillDismiss`/`inlineReaderDismissalDidCancel`/`inlineReaderDidDismiss`/
  `inlineReaderTopEdgeInWindow`, lines 1361,1364,1368,1372,1376,1381) directly, rather than going through a
  closure like every other reader in the stack does. It's also keyed on the concrete type instead of the
  `InlineReaderPresentationCoordinating` protocol that RSVP/RabbitHole use for the identical lookup — the one
  place in the cluster that breaks the "closures/protocols only" boundary contract.
- **`RabbitHoleLayerViewController.lineText(for:)` (line 697, `public`) has zero external callers** — its only
  call site anywhere in the repo is internal to the same file — over-exposed API rather than a violation, but
  worth tightening alongside the dead/over-exposed sweep in §2.5.
- **Reader→carousel host lookups use two different mechanisms for the same purpose**: RSVP/RabbitHole walk
  `parent` for anything conforming to `InlineReaderPresentationCoordinating`; `ScrollReaderViewController`
  walks `parent` for the concrete `ReaderViewController` type (see above). Behaviorally equivalent today only
  because `ReaderViewController` happens to be the sole conformer reachable from that call path — a latent
  trap if a second conformer is ever added on that path.
- **Everything else checked was clean**: `RabbitHoleReaderViewController.applyFocus()` (276-292, "the only
  writer of layer frames" per its own comment) touches only `layer.view.frame/.zPosition/.alpha` and the
  layer's own public API — never reaches into `RabbitHoleLayerViewController`'s header/lip/menu subviews.
  `ArticleCardsViewController` never constructs `ReaderViewController`/`InlineReaderPageViewController`/
  `RabbitHoleLayerViewController` directly — only through `ReaderHostFactory.make(...)` for the whole reader,
  and thereafter only through `ReaderChromeControlling`/`InlineReaderPresentationCoordinating`. `SplitWebOverlayViewController`
  never references any concrete carousel/host type — all host-awareness is via the protocol, with geometry
  handed in at construction rather than reached for. `LinkRSVPPreviewViewController` is `private` to its file
  so no external violation is possible there. `WordMap`/`ArticleTextRenderer` are pure model types never
  handed a live view to mutate.

### 2.3 Duplicated or disjoint-but-related logic

**(a) `LinkRSVPPreviewViewController` substantially re-implements `RSVPViewController`'s playback engine — the largest duplication in scope.**
`LinkRSVPPreview.swift`'s `showCurrentWord()` (761-779, ORP-highlighted word rendering), `scheduleNext()`/
`startWordTimer()`/`applyTemporaryWPM()` (828-874, timer-driven word advance with mid-flight WPM rescale),
`skip(by:)` (925-944, via `RSVPEngine.skipTarget`), and the `AudioPlaybackObserver`/`AudioWordEventTokenMapping`
sync (1020-1038) mirror — largely method-for-method — `RSVPViewController.swift`'s own `scheduleNext()` (1157),
`skip(by:)` (1257), and `AudioWordEventTokenMapping` usage (1344,1452). Two independently-evolved RSVP engines
exist in this module; a shared "RSVP playback core" (word-timer + skip + ORP render + audio-center sync) that
both the full-screen reader and the link-preview card drive would remove the largest duplication surface here.
Related, smaller duplication in the same area: `LinkRSVPPreview.swift:781-796`'s `setContextVisible`/`updateContext`
(±12-word context window) parallels RSVP's own context-label logic (`RSVPViewController.swift:964-974`,
`updateContextVisibility`).

**(b) Finish-detection is duplicated with different edge tests, same shape.**
```swift
// ScrollReaderViewController.swift:1163-1172
guard didLoadFullContent, textView.contentSize.height > 0 else { return }
let reachedEnd = visibleBottom >= textView.contentSize.height - 40
if reachedEnd, !didFinishReading { didFinishReading = true; onFinishedReading?() }
else if !reachedEnd, didFinishReading { didFinishReading = false; onMovedAwayFromEnd?() }
```
```swift
// RSVPViewController.swift:1212-1219, 1378-1386
private func finish() { guard !didFinishReading else { return }; didFinishReading = true; ...; onFinishedReading?() }
if isAtEnd() { finish() } else if didFinishReading { didFinishReading = false; ...; onMovedAwayFromEnd?() }
```
Same fire-once/fire-back state machine, independently written per reader (scroll-ratio edge test vs.
frame-index edge test) — candidate for a shared `FinishedReadingTracker` helper mirroring the already-shared
`ReaderResumePositionResolver`.

**(c) Identical 0.5pt-debounce chrome-inset property pattern, duplicated verbatim:**
```swift
// ScrollReaderViewController.swift:166-171                    // RSVPViewController.swift:120-125
public var topChromeInset: CGFloat = 0 {                       public var topContentInset: CGFloat = 0 {
    didSet {                                                        didSet {
        guard abs(topChromeInset - oldValue) > 0.5 else { return }      guard abs(topContentInset - oldValue) > 0.5 else { return }
        applyTopChromeInset(...)                                        subModeTopConstraint?.constant = topContentInset + 8
    }                                                                }
}                                                                }
```
Same guard constant and shape, different application target — worth a tiny shared helper/property wrapper
even though the effect necessarily differs by view type.

**(d) Play/pause glyph sync duplicated 4× in `RSVPViewController`** instead of centralizing on `isPlaying`'s
own `didSet` (61-65, which currently only fires `onPlaybackStateChanged`): lines 300-302
(`syncPlaybackStateToCenter`), 993-994 (`play()`), 1046-1047 (`pause()`), 1438-1439
(`audioPlaybackCenter(_:didChangeState:)`) each manually re-set `playPauseButton.configuration?.image` +
`accessibilityLabel` in lockstep. A single `updatePlayPauseGlyph()` driven from `isPlaying`'s `didSet` removes
all 4 copies.

**(e) The "dispatch on mode" triad is duplicated 3× in `RSVPViewController`**: `play()` (996-1003), `skip(by:)`
(1287-1294), and `rescaleRunningInterval` (1129-1136, the 2-way half) all re-derive
`if isSpeechMode {…} else if displayMode == .phrases {…} else {…}` independently.

**(f) The "route to `showWord` vs. `showChunk`" pair is duplicated 5× in `RSVPViewController`**: `refreshDisplay`
(862-867), `audioPlaybackCenter(_:didEmitWordEvent:)` (1462-1467),
`speechSynthesizer(_:willSpeakRangeOfSpeechString:...)` (1491-1497), `speechSynthesizer(_:didFinish:)`
(1514-1519), and `seek(toWord:)` (implicitly, via `refreshDisplay`). A single `render(at:highlightWord:)` helper
would collapse 4 of the 5 hand-rolled copies.

**(g) Two independent whitespace-tokenization schemes for "word index" are kept in sync by convention, not by sharing code.**
`RSVPEngine.tokensWithURLs(in:)` (`RSVPEngine.swift:80-112`) and `WordMap`'s own tokenizer
(`WordMap.swift:9-25`) both split on whitespace to build a word-index space — `WordMap`'s own comment admits
"Tokenize exactly like RSVPEngine." Similarly, `AudioWordEventTokenMapping.blockTokenStarts`
(`ReaderAudioLauncher.swift`) explicitly says it mirrors "RSVPEngine's tokenizer" for the audio-center's
block+UTF16-offset scheme. Three tokenizers, one intended invariant, zero shared code — any future change to
tokenization rules has three places to update in lockstep.

**(h) Voice-resolution logic is duplicated across the legacy and new read-aloud systems.**
`SpeechEngine.swift`'s `AppleEnhancedEngine.bestEnhancedVoice` (79-90) and `LunaAudioPlayback/AudioVoiceResolution.swift`
(outside this slice) independently resolve "best installed enhanced/premium voice for the locale" — the newer
file's own doc comment confirms this is an intentional mirror, not an oversight, but it's still logic that
drifts independently if Apple changes voice-quality tiers.

**(i) `ArticleTextRenderer.downsampledImage` re-implements image downsampling instead of calling the shared helper.**
`ArticleTextRenderer.swift:240-261` hand-rolls the same `CGImageSourceCreateWithURL` +
`kCGImageSourceCreateThumbnailFromImageAlways/...` recipe (plus its own `NSCache`, 230-236) that
`LunaDesignSystem/ImageDownsampling.decode(path:scale:maxPixelSize:)` already provides (added by
PERF_REVIEW_PLAN item 6, and in live use elsewhere: `AudioMiniPlayerView.swift:255`,
`CatchUpSubviews.swift:314,572`, `NowPlayingCoordinator.swift:217`, `ReadingListItemCell.swift:373`). Not
migrated when the shared helper was added — `ImageDownsampling.decode` is itself synchronous, so it could be
called directly without disturbing `ArticleTextRenderer`'s main-actor-synchronous rendering contract.

**(j) `SplitWebOverlayViewController` vs. `ArchiveWebReaderViewController`/`OriginalPageViewController` — checked directly, mostly NOT duplicated.**
WKWebView setup, paywall handling, and navigation-delegate boilerplate are legitimately different per file
(nested-reader chrome vs. CAPTCHA-solving vs. static-archive-replay) — no redundant boilerplate to extract.
The one real asymmetry: `ArchiveWebReaderViewController` has **zero animation** (pure `.isHidden` toggling for
every state transition — 605,751,764,769,931,980-1002) in stark contrast to `SplitWebOverlayViewController`'s
spring/fade tab choreography — a design-consistency gap, not a bug (see §2.7).

**(k) Three different link-activation shapes for conceptually the same "user tapped a link" event.**
`SplitWebOverlayViewController.pushPage`/`makePage` pushes a new page onto its own inner nav stack;
`RSVPViewController.activateLink` and `RabbitHoleReaderViewController.presentInlineReader` both *create a new*
`SplitWebOverlayViewController` instead. Likely intentional (top-level readers must create the overlay; the
overlay, once open, just pushes internally) but worth a design-consistency confirmation.

**(l) `HorizonScrollIndicator` is integrated two different ways** — `SplitWebOverlayViewController` uses
`.makeHosted()` + manual `.track()`/frame layout (68,568-584); `OriginalPageViewController` uses the static
`.install(on:in:)` convenience (81) — same shared component, two integration styles, also used by
`ScrollReaderViewController`/`RabbitHoleLayerViewController`/`InlineReaderPageViewController`.

**(m) `RabbitHoleLayerViewController.markEmbeddedItemRead`/`unmarkEmbeddedItemReadIfAutoMarked` (756-772) is *self-documented* intentional duplication** of `ReaderViewController`'s mark/unmark dance (its own doc comment at 74-77 says so) — flagged only for completeness, not an oversight.

### 2.4 Overly complex code — god classes/methods, region maps, extraction seams

#### `RSVPViewController.swift` (1542 lines) — region map

| Lines | Region |
|---|---|
| 1-27 | Header / class doc |
| 28-193 | Stored state: closures (31-46), model/engine (48-72), speech-center plumbing (74-110), sub-mode (112-125), subviews (127-172), gestures/press-hold (169-178), sizing constants (180-193) |
| 195-213 | `init` |
| 220-228 | `resolveResumeFrame` |
| 233-288 | `configureForReuse` — **god method** |
| 296-304 | `syncPlaybackStateToCenter` |
| 306-338 | `required init?`, `currentReadingWordIndex`, font-sizing statics |
| 340-382 | `viewDidLoad` — **god method** |
| 384-433 | lifecycle + audio-session helpers |
| 437-637 | sub-mode control, focus-pill, word/phrase labels, context labels, link pill config/layout |
| 639-691 | `activateLink` — **god method** (+ dead branch, §2.5) |
| 693-801 | `configureLinkPreview`, `configureControls` — **god method** |
| 805-858 | sub-mode switching, `chunkIndex(forWord:)` binary search |
| 862-975 | display rendering (`refreshDisplay`/`showWord`/`showChunk`/context) |
| 978-1097 | playback core (`play`/`playViaCenter`/`pause`/sentence-TTS pacing/`togglePlayPause`) |
| 1101-1219 | press-and-hold slow-motion, Words-mode timer, Phrases-mode timer |
| 1223-1311 | scrub gesture, skip/seek — `skip(by:)` borderline-god |
| 1313-1387 | WPM adjustment, center-sync helpers, progress persistence, finish bookkeeping |
| 1391-1421 | end-of-article share view |
| 1423-1524 | `AudioPlaybackObserver` + `AVSpeechSynthesizerDelegate` extensions |
| 1526-1541 | `UIGestureRecognizerDelegate` extension |

**God methods**: `configureForReuse` (233-288, 56 lines — 5 mixed concerns: reset, model rebuild, resume-
resolution, conditional UI rebuild, center resync — split into `resetTransientState()`+`applyContent(...)`);
`configureControls` (715-801, 87 lines, linear-but-long — split per control group); `activateLink` (639-680,
42 lines — pause + 3-way dispatch + 5 near-identical closure wire-ups, one branch dead, §2.5); `viewDidLoad`
(340-382, ~42 lines — 7 `configure*` calls + duplicate initial-state derivation already done by `init`);
`skip(by:)` (1257-1295, 39 lines, branching-dense). See §2.3(d-f) for the three cross-method duplication
patterns inside this file (glyph sync ×4, mode-dispatch triad ×3, showWord/showChunk routing ×5) — these are
the highest-value extraction seams, since fixing them shrinks the god methods too.

**Redundant state**: `didFinishReading`/`didRevealShare` (149/148) are read/reset together in
`updateFinishedReadingState()` (1377-1387) but not fully mirrored (different guard conditions) — a 3-case enum
(`.reading`/`.finishedNoShare`/`.finishedSharing`) would make the relationship explicit. `isSpeedHeld` +
`intervalStart` + `intervalDuration` (173,177-178) are three fields for one "in-flight interval, possibly
slowed" concept — a single-struct candidate, no correctness issue found.

#### `ScrollReaderViewController.swift` (1510 lines) — region map

| Lines | Region |
|---|---|
| 1-171 | closures (17-50), state incl. shared-position tracking/content state/highlight/share (51-171) |
| 173-295 | `init`, `configureForReuse` — **god method** |
| 297-401 | resume heuristic, position getters, `deinit`, `makeShareView` |
| 403-501 | `layoutShareView`, `viewDidLoad` — **god method**, chrome inset, `viewDidLayoutSubviews` |
| 542-642 | progressive 2-phase load (`prepareFullContent`/`applyFullContent` — **god method**/`installPositionDependentFeatures`) |
| 644-778 | inline images + gesture routing (image tap, sentence long-press, context menu) |
| 779-880 | scroll-position restore + appearance lifecycle |
| 881-1054 | playback UI (`configureFooter`, transport actions, `startSpeech` — **god method**) |
| 1055-1174 | highlighting, `UIScrollViewDelegate` (scroll settle, `checkFinishedReading`) |
| 1175-1264 | link taps → split (`textView(primaryActionFor:)`, `link(at:)`) |
| 1265-1394 | selection highlight/share, `openSplit`, `enclosingReaderViewController`, `#if simulator` debug hooks |
| 1443-1510 | `restoreScroll`, `SpeechControllerDelegate` extension, `AudioPlaybackObserver` extension |

**God methods**: `configureForReuse` (223-295, 73 lines, high branch count — split `resetTransientState()` +
`applyContent(...)`); `viewDidLoad` (421-501, 81 lines, mixes 5 unrelated concerns incl. 3 duplicated
`if full-content-already-loaded` guards in a row); `applyFullContent` (574-621, 48 lines, offset-preservation
math that re-derives glyph-rect geometry computed elsewhere); `startSpeech` (986-1034, 49 lines, two entirely
separate code paths — center-driven vs. legacy `SpeechController` — glued by an early return, reads as two
methods).

**Redundant state**: `didLoadFullContent`/`didBeginFullContentLoad` (101,103) — candidate 3-state enum
(`.notStarted`/`.loading`/`.loaded`). `committedWordIndex`/`committedOffsetY`/`landedGlanceFling` (67,68,73)
always read/written together — candidate single struct.

#### Other large-file complexity findings

- **`LinkRSVPPreview.swift`**: `LinkRSVPPreviewInteraction.handleGesture(_:)` (318-376, 59 lines — the
  `.began` case alone is 35 lines mixing haptics/overlay/async-fetch/child-VC-mount/closure-wiring);
  `LinkRSVPPreviewViewController.viewDidLoad()` (531-582, 52 lines, flat construction, lower risk). Seven
  boolean state flags (`isShowingTitle`,`isPausedByMenu`,`isPausedByHorizontalDrag`,`isPausedByControl`,
  `isAudioMode`,`isLockArmed`,`isLocked`) combined ad hoc via ORs in `isPlaybackPaused` — candidate playback-
  state enum (with lock kept orthogonal).
- **`RabbitHoleLayerViewController.swift`**: `configureChrome()` (315-378, 64 lines), `layoutChrome()`
  (380-424, 45 lines, manual frame math incl. dynamic trailing-slot width), `embedReader(mode:forceReembed:)`
  (671-724, 54 lines — original-mode short-circuit + duplicated per-mode closure wiring between `.scroll`/
  `.rsvp` cases). Redundant mirroring: `readerMode` (line 66) mirrors `descriptor.readerMode`, written at 4
  separate call sites (228,544,683,722) that must be kept in sync by hand.
- **`RabbitHoleReaderViewController.swift`**: `presentInlineReader(...)` (305-350, 46 lines, 5 near-identical
  `[weak coordinator, weak overlay]` forwarding closures — same shape as Cluster 2 in §2.1); `makeLayer()`
  (232-266, 35 lines of repeated weak-capture boilerplate — resolved by the Cluster-1 delegate protocol).
- **`ArchiveWebReaderViewController.swift`**: `checkStage()` (547-647, 101 lines incl. an inline JS-probe
  literal — orchestration around an already-well-factored pure `decideStage`); `checkDirectBypassStage()`
  (699-785, 87 lines, same poll/CAPTCHA/JS-gate shape as `checkStage` — direct duplication between the two
  pre-stage legs); `extractAndSave()` (880-940, 61 lines, 5 concerns: JS extraction, challenge re-check,
  off-main parse, store write, archive capture).
- **`SplitWebOverlayViewController.swift`**: `rebuildTabs(animateNewest:animateReflow:)` (333-417, 85 lines,
  3 interleaved animation paths mutating shared flags from inside completion blocks);
  `InlineReaderPresentationController.presentationTransitionDidEnd` (643-684, 42 lines, 3 ad-hoc overlay views
  built inline). 5-flag state machine (`isNavigatingInlineStack`/`isAnimatingTabLayout`/`pendingTabInsertion`/
  `pendingTabRemovalAnimation`/`pendingSourcePoint`, 79-85) coordinating the inner nav controller with the
  tab-strip animation — candidate single enum state.
- **`LunaReaderEngine/ChunkPlanner.chunkEnd(words:start:)`** (72-121, ~50 lines) is the one genuinely
  over-40-line method in the pure-logic tier — three sequential phases (budget scan, overrun-tolerant
  re-scan, hard-boundary checks), well-commented; flagged for awareness, not recommending a mechanical split
  without behavior risk.

### 2.5 Dead/unused code

Every item below was grep-verified across `Luna/`, `LunaLibraries/Sources`, `LunaLibraries/Tests`,
`LunaTests/`, and the extension/clip targets (excluding `build/`, `.claude/`, `.git`).

| Item | File:line | Verification |
|---|---|---|
| `RSVPViewController.onLinkActivated` (plain variant) | `RSVPViewController.swift:38`, read `:645-648` | `grep -rn "\.onLinkActivated = \|rsvp.*onLinkActivated"` across all real source → zero setters. Dead branch. |
| `ScrollReaderViewController.onLinkActivated` (plain variant) | `ScrollReaderViewController.swift:28`, read `:1187-1188` | Same grep pattern → only hit is an unrelated same-named property on a different type (`RabbitHoleReaderViewController.swift:238`). Dead branch. |
| `InlineReaderPageViewController.onLinkActivated` (plain variant) | `InlineReaderPageViewController.swift:31`, read `:323,337` | Sole real caller `SplitWebOverlayViewController.makePage` always sets `onLinkActivatedAtPoint` instead (line 231) — `grep -n "onLinkActivated =" SplitWebOverlayViewController.swift` → no match. Dead branch. |
| `SplitWebOverlayViewController.chromeSave()` (empty `{}`) + `RabbitHoleReaderViewController`'s `chromeSave`/`ReaderChromeState.isSaved` | `SplitWebOverlayViewController.swift:554`; `RabbitHoleReaderViewController.swift:436` (impl.), `:32` (`isSaved` field) | `grep -rn "\.chromeSave("` → zero call sites anywhere. Root cause: the one chrome host, `ArticleCardsViewController.swift:333-336`, only wires a share button — there is no "Save" affordance in the shared chrome row at all. `isSaved` is written (RabbitHole:425, SplitWebOverlay:539 hardcodes `false`) but never read by the host. |
| `SplitWebOverlayViewController.onClose` | decl `:52`, invoked `:209` | `grep -rn "\.onClose\b"` → no assignment anywhere (distinct from `ArchiveWebReaderViewController.onClose`, which is live). Dead. |
| `SplitWebOverlayViewController.init` params `lineHeight`/`topHalf`/`bottomHalf` | `:92-95` (accepted, never read in body) | All 6 call sites (RSVP:652-653, ScrollReader:1357-1358, RabbitHole:319-322, UITestScreen:125-126, 2× InlineReaderTabMetricsTests) literally pass `lineHeight: 0, topHalf: nil, bottomHalf: nil`. Doc comment (87-88) already concedes this ("Legacy split arguments remain accepted..."). |
| `SplitWebOverlayViewController.init` param `cutY`'s fallback branch | `:104` (`sourcePoint ?? CGPoint(x:..., y: cutY)`) | Every current call site passes `sourcePoint:` non-nil — fallback unreachable in practice; not yet mentioned in the doc comment. |
| `RabbitHoleReaderViewController.rootItemID` | `:81` | `grep -rn "rootItemID"` → only its own declaration. Its doc comment claims the mini-player uses it for tap-to-return, but that lookup actually goes through `containsReaderItem(withID:)` (`MiniPlayerHostViewController.swift:361,371`) — stale doc + dead property. |
| `.highlight`/`.original` switch arms, `RabbitHoleLayerViewController.swift` | `:691` (`case .scroll, .highlight, .original:`), `:836` (`case .scroll, .highlight:`) | `readerMode`/`descriptor.readerMode` are only ever written at 4 sites (228,544,683,722), none producing `.highlight`; `.original` at 691 is also excluded by `embedReader`'s own early-return guard at line 673. Both dead in practice — same retirement already documented for `.highlight` in `ReaderViewController.swift:373`. |
| `.highlight` switch arms, `ReaderViewController.swift` / `InlineReaderPageViewController.swift` | `ReaderViewController.swift:247,372`; `InlineReaderPageViewController.swift:69,327` | `.highlight` is unconditionally remapped to `.rsvp` in `ReaderViewController.init` (99-102); `setMode`'s only caller (`SplitWebOverlayViewController.chromeSetMode:542`) is restricted to `orderedModes = [.scroll,.rsvp,.original]` (`:75`) — `.highlight` can never reach either. Kept for `Codable` decode of old persisted `.highlight` values (`LunaModels/ReadingListItem.swift:44-48`), but the case *arms in these reader VCs* are provably unreachable. |
| `ReadingHeuristics.hasDigit(_:)` | `ReadingHeuristics.swift:69` | `grep -rn "hasDigit"` across all real source → only its own definition. Zero callers. `difficultyFactor` (line 112) reimplements the identical check inline (`word.contains(where: \.isNumber)`) instead of calling it. |
| `InlineReaderTabMetrics.init(availableWidth:tabCount:minimumTabWidth:)` + `.tabWidth` | `InlineReaderEclipseTransition.swift:38-44,78` | Zero production callers (`grep -rn "InlineReaderTabMetrics("` → 1 production call, always the `idealWidths:` initializer; the `tabCount:` convenience init and `.tabWidth` are exercised only by `InlineReaderTabMetricsTests.swift`). Test-only surface despite the doc comment implying real callers exist. |
| `RSVPEngine.makeWord(_:isLastInBlock:url:)` | `RSVPEngine.swift:114` (`public static`) | Only caller is its own `init` (line 54). Over-exposed, not dead — candidate `private`. |
| `WordSplitter.hyphenSplit`/`hardWrap` | `WordSplitter.swift:28,41` (`public`) | Only callers are `WordSplitter.split` itself. Over-exposed. |
| `PaywallUnlockRules.expandAlternations`/`expansionLimit` | `PaywallUnlockRules.swift:66,74` (`internal`, not `private`) | Self-referenced only (recursion). Over-exposed. |
| `RabbitHoleLayout.visibleAncestors`/`cardFrame` | `RabbitHoleLayout.swift:67,84` (`public`) | `grep -rn "\.visibleAncestors(\|\.cardFrame(steps"` → zero external callers; both used only internally by `placement(...)`, which is the sole entry point every real consumer (`RabbitHoleReaderViewController.swift:281`, `RabbitHoleLayoutTests.swift:18`) calls. Over-exposed. |
| `RabbitHoleLayerViewController.lineText(for:)` | `:697` (`public`) | Only call site is internal to the same file. Over-exposed. |
| `RabbitHoleLayout.maxVisibleAncestors` | `:… default 2` | Never overridden from its default anywhere (`grep "layout\.\w+ *="` → zero hits for any of the 4 tunables); load-bearing internally but exposed as a `public` knob no one currently tunes. |

**Confirmed NOT dead (checked and cleared)**: `InlineReaderContentLoader`, `ReaderHostFactory`,
`ReaderProviders` (both protocols), `WebArchiveCapturer`'s two factories, `EpubBuilder.escapeXML`,
`MIMEMessage.encodedHeaderText`, `DocumentParser`'s three entry points, `Array.subscript(safe:)`'s
intentional double-declaration (`WordMap.swift:66` / `LunaAudioPlayback/AudioPlaybackWordIndexing.swift:91`
— self-documented dependency-graph trade-off, not an oversight).

### 2.6 Comment hygiene

Every comment below matched the "narrates a past change / absent behavior" grep across all 39 files
(`no longer|instead of|previously|we now|rather than|used to|as before|the old|no changes to`) and was
individually reviewed; comments that are present-tense design rationale ("X rather than Y" explaining a
*current* choice against a live alternative) are the large majority of raw grep hits and are **not** listed
— only genuine before/after narration is below.

| File:line | Current text | Issue | Rewrite |
|---|---|---|---|
| `ReaderViewController.swift:186` | `// De-glassed (Task 3): an opaque solid background instead of the blurred` | Narrates a tracked-task change | `// Opaque solid background (not translucent) so the bar reads consistently against the solid reader background.` |
| `ScrollReaderViewController.swift:551` | `"...generation no longer stalls the open."` (inside `prepareFullContent` doc comment) | Implicit before/after framing | `"...generation runs off the entry animation's critical path."` |
| `LinkRSVPPreview.swift:309` | `"…everything else behaves exactly as before. Pans stay independent…"` | "Before" undefined for a reader without git history | `"…everything else behaves exactly as it would without this interaction installed."` |
| `RabbitHoleLayerViewController.swift:735` | `"…the per-session scroll offset comes from the descriptor, exactly as before."` | Same issue, no "before" state described anywhere nearby | Delete trailing clause: `"…the per-session scroll offset comes from the descriptor."` |
| `RabbitHoleLayerViewController.swift:829` | `"…the archive can never clobber the shared scroll/RSVP position (the old bug):"` | References an undescribed historical bug | Delete parenthetical: `"…the archive can never clobber the shared scroll/RSVP position:"` |
| `RabbitHoleLayerViewController.swift:805` | `// MARK: - Scroll access (no changes to ScrollReaderViewController)` | Section header claims an absence-of-change relative to an unstated baseline | `// MARK: - Scroll access` (the fork provenance is already stated once at the file's top, lines 5-9) |

**Also flagged as a density concern (not matching the exact banned phrases, so not individually rewritten):**
the `.highlight`-mode-retirement story is repeated at 7 separate call sites (`ReaderViewController.swift:15-16,41,72,99-101,247,372-373`;
`InlineReaderPageViewController.swift:328`) instead of once on the enum itself
(`LunaModels/ReadingListItem.swift:47`, which already documents it) — once the dead switch arms in §2.5 are
removed, most of these repetitions disappear naturally.

**Reviewed and cleared (present-tense rationale, no action)**: `RSVPViewController.swift:1353` (explains
*why* a value goes stale, not a past change); `ScrollReaderViewController.swift:25-27,54,164,179,354,417,701,996,1505`;
`ArchiveWebReaderViewController.swift:67,149,158,693,950`; `SplitWebOverlayViewController.swift:44,816,87-88`;
`ArticleImageDownloader.swift:71,127`; `PaywallUnlockRules.swift:42,264`; `EpubBuilder.swift` (no matches);
`SpeechController.swift:53-63` and `SpeechControllerAudioTrimmingTests.swift:68` (load-bearing "Phase 6" index-
preservation documentation, not stale narration).

### 2.7 Animation structure

**The eclipse/immersion system is correctly centralized where it's used for VC-to-VC presentation:**
`InlineReaderEclipseTransition.swift`'s `InlineReaderEclipseScene`/`InlineReaderEclipseAnimator` is the single
canonical implementation (circle-grows → black-eclipse-rises → corona flare, full reduce-motion cross-fade
path) and is used **exclusively** by `SplitWebOverlayViewController` for both its outer VC-presentation
transition (forward/reverse, lines 190-213) and its inner nav push/pop transition (268-287) — no reader VC
duplicates this logic ad hoc; `ReaderViewController`/`InlineReaderPageViewController`/`ScrollReaderViewController`/
`RSVPViewController`/`RabbitHoleLayerViewController` all correctly defer to it rather than reimplementing.
`sceneContainer`/`sceneFrame` are genuinely exercised with 2 distinct coordinate-space configurations (outer
vs. inner transitions) — not over-generalized.

**Everything outside that one system is ad hoc, with real duplication and one striking omission:**

- **`RSVPViewController`**: 4 fade blocks, 4 independently-chosen durations (0.2/0.25/0.05-0.2-0/0.3), no
  shared timing/curve constants (618,631,972-973,1419). No `CADisplayLink`/spring animation anywhere.
- **`ScrollReaderViewController`**: only 2 blocks — a 0.15s reveal fade (808) and a 0.25s linear scroll-follow
  during read-aloud (1079-1081) — minimal and self-contained.
- **`LinkRSVPPreview.swift`**: the richest ad-hoc animation surface — 7 distinct blocks (card-entrance
  spring via `UIViewProperty Animator`/`UISpringTimingParameters(dampingRatio:0.86)`, lock-glyph fade,
  chin-grow, dismiss-fade, context cross-fade, menu fade, hint fade) — none reuse the eclipse system (by
  design — different kind of transition), but they're 7 independently-tuned micro-animations with no shared
  constants either.
- **`SplitWebOverlayViewController`**'s tab-strip animations (reflow: `curveEaseInOut` 0.3s; new-tab drop-in:
  spring `damping:0.82, velocity:0.55`; hide-behind: `curveEaseIn` 0.18s) are a **second**, separate ad-hoc
  animation system living alongside its correct use of the shared eclipse animator for presentation — worth
  distinguishing "presentation transition" (shared, correct) from "tab chrome micro-animation" (ad hoc,
  self-contained) when reasoning about this file.
- **`ImageLightboxViewController`** implements a fully bespoke interactive-dismiss transition (open: 0.28s
  ease-out expand-from-source-frame; pan-tracking via `CGAffineTransform` scale + spring-back
  `damping:0.85`; fling-away: 0.25s ease-out) entirely outside `UIViewControllerTransitioningDelegate` — a
  second, independent "zoom from thumbnail" transition implementation that a future second image viewer
  would have to reimplement by hand rather than reuse.
- **`ArchiveWebReaderViewController` has zero animation** — every state transition (CAPTCHA reveal, stage
  overlays, terminal messages) is an instant `.isHidden` flip (605,751,764,769,931,980-1002) — a real
  contrast with `SplitWebOverlayViewController`'s spring choreography one file over in the same module
  (flagged in §2.3(j) as well).
- **`RabbitHoleReaderViewController`'s actual dive/pop transition — the core UX this feature is named for —
  has no bespoke animation at all.** `applyFocus()` (276-292, the sole writer of layer frame/alpha/zPosition)
  sets every value directly with no `UIView.animate` wrapper; both `pushLayer` (296-303→300) and `popToLayer`
  (463-470→467) call it unanimated, snapping the new/previous layer into place instantly. The **only**
  animated call to `applyFocus()` is inside `viewWillTransition(to:with:)` (188-191, a system-driven rotation
  relayout). Worth confirming with the feature owner whether the snap-instantly dive/pop is intentional (e.g.
  a different visual cue carries the transition) or a genuine gap — it stands out sharply next to
  `LinkRSVPPreview.swift`'s elaborate spring entrance for what is visually the "same" card-stack feature.

---

## 3. Test coverage note

| Area | Direct coverage | Notable gaps |
|---|---|---|
| `RSVPViewController` | `LunaTests/ReaderScreenTests.swift` (snapshots, mode-switch hosting, finish/unmark via real store, scrub-persist-on-touch-up); `RSVPAudioResyncTests.swift` (center-driven `configureForReuse` resync) | Phrases sub-mode switching, press-and-hold slow-motion, private-synthesizer read-aloud path (`AVSpeechSynthesizerDelegate`), the dead `onLinkActivated` branch |
| `ScrollReaderViewController` | `ReaderScreenTests.swift` (snapshots, finish-detection, mark/unmark wiring, mode-switch hosting); `ArticleTextRendererProgressiveTests.swift` (progressive-swap VC test); `HighlightShareTextTests.swift` (pure fn only) | chrome-inset application, sentence long-press, glance-fling detection, link hit-testing (`link(at:)`), image tap/lightbox, share-footer-visibility threshold logic |
| `LinkRSVPPreview.swift` | `LinkRSVPPreviewGesturePolicyTests.swift` (pure gesture-policy functions only) | **Zero coverage of `ArticleRSVPPreviewSession`, `LinkRSVPPreviewInteraction`, `LinkRSVPPreviewViewController`** — the entire mini playback engine, async-load race handling, haptics, menu/chin UI |
| `RabbitHoleLayerViewController` | `RabbitHoleStackStoreTests.swift:20-49` (2 tests, narrowly on `modeSegmentCountForTesting` after `configure`) | Article probe, embed/mode-switch machinery, chrome pill construction/layout |
| `RabbitHoleReaderViewController` | **None** (`grep -rn "RabbitHoleReaderViewController" LunaTests` → zero hits) | `pushLayer`/`popToLayer`/`applyFocus`/persist/`chromeState`, gesture-delegate overscroll/edge-pop logic — the whole file |
| `SplitWebOverlayViewController` | `InlineReaderTabMetricsTests.swift` (2 VC-level tests: presentation-style/delegate-identity, dismiss-fires-once) + thorough pure-geometry tests | Tab animation state machine, link push/pop, `rebuildTabs`, chrome forwarding |
| `ArchiveWebReaderViewController` | `ArchiveStageDecisionTests.swift` (pure `decideStage`/`isJavaScriptRequiredGate` only, 12 tests); `ArchiveWebPreStageTests.swift` (1 test, `webPreStageURLs`) | `checkStage()`/`checkDirectBypassStage()` orchestration, `extractAndSave()` — all untested end-to-end (understandably, given real WKWebView/network dependency) |
| `OriginalPageViewController` | **None** | Scroll-offset restore, archive/document/live-URL fallback chain, `persistsScrollOffset` branch |
| `WebArchiveCapturer` | **None — no test file exists** | 20s timeout, 900ms settle delay, "suspiciously tiny archive" heuristic (line 73) |
| `InlineReaderEclipseTransition` | **None** (`grep -rln "Eclipse" LunaTests` → no results) | The actual animation code (`InlineReaderEclipseScene`/`InlineReaderEclipseAnimator`) — forward/reverse choreography, reduce-motion branch |
| `SpeechController` | `SpeechControllerAudioTrimmingTests.swift` (pure `speakableBlocks` filter only) | No test drives an actual instance — play/pause/skip/rate-cycle/word-mapping, `AVSpeechSynthesizerDelegate` callbacks |
| `SpeechEngine`/`SpeechVoice`/`ReaderAudioSession`/`VoiceFirstRunPrompt`/`VoiceModelStore` | None directly | Thin wrappers, some hard to test meaningfully (device/simulator branches); `VoiceModelStore` gates a user-visible prompt with no direct test |
| `ArticleImageDownloader` | None directly (`ArticleCoverThumbnailTests.swift` only hand-mirrors its hashing scheme for fixtures) | Dedup/budget/transcode logic entirely untested at this layer |
| `ArticleShareView` / `ImageLightboxViewController` | None | — |
| `ReadingHeuristics` | `ReadingHeuristicsTests.swift` (thorough on live members) | `hasDigit` untested (consistent with it being dead) |
| `RSVPEngine.frameIndex`/`tokenIndex` | **None directly** (`RSVPEngineTests.swift` never calls either name) | The exact token↔frame mapping a past bug fix (`CODE_REVIEW_PLAN.md` commit `365d7ef`) targeted has no direct regression test — only indirect UI-level coverage |
| `DocumentParser` PDF/RTF paths | None | `parsePDF`/`parseRTF` (lines 35-54) — the two branches using external frameworks, zero fixture-based tests |
| `PaywallUnlockRules.compiledRuleList`/`cleanupUserScript`; `SiteCleanupScripts.userScript` | Underlying data/JSON tested; the `WKUserScript`/compile wrapper factories are not | — |
| `EpubBuilder` duplicate-image dedup | Indirect (no test with 2+ blocks referencing the same image) | No regression test for the specific case `CODE_REVIEW_PLAN.md` commit `eb82df3` fixed |
| `InlineReaderContentLoader`/`ReaderHostFactory`/`ReaderProviders` | Only indirectly, via higher-level snapshot/integration tests | No dedicated unit test for the article-probe/embed state machine or cache-hit/miss branches |
| `WordMap`, `ChunkPlanner`, `RSVPEngine` (core), `WordSplitter`, `RabbitHoleLayout`, `RabbitHoleStackStore`, `ReadingHeuristics`, `PaywallUnlockRules`, `SiteCleanupScripts`, `EpubBuilder`, `MIMEMessage`, `DocumentParser` (txt/markdown) | **Good, thorough** | — |

---

## 4. Top 10 highest-value changes

Ranked by (impact on the refactor plan) × (how well-scoped the fix already is from this audit). Effort:
S = &lt; half a day, M = 1-2 days, L = multi-day / needs care across files.

1. **[M] Consolidate the `RabbitHoleLayerViewController` → `RabbitHoleReaderViewController` 6-closure cluster into one delegate protocol.** Highest closure density in the audit, single collaborator, one set-site (`makeLayer()`), removes repeated weak-capture boilerplate outright. See §2.1 Cluster 1.
2. **[M] Consolidate `SplitWebOverlayViewController`'s 5-closure presentation-coordinator wiring**, duplicated identically at 3 production call sites (RSVP/ScrollReader/RabbitHoleReaderViewController) plus the duplicated ancestor-walk helper — one `wireCoordinator(_:)` helper or protocol-default-extension removes ~60 lines of copy-paste. See §2.1 Cluster 2.
3. **[S/M] Introduce a shared `ReaderCompletionDelegate` (`onFinishedReading`/`onMovedAwayFromEnd`)** implemented by both `RSVPViewController` and `ScrollReaderViewController`, replacing the identical closure pair wired by both hosts. Small, mechanical, high signal for "this is the pattern to follow" going forward. See §2.1 Cluster 3.
4. **[S] Extract the "point-or-plain link-activation forwarding" idiom into one helper**, and delete the now-provably-dead plain `onLinkActivated` variant at all 5-6 sites in the same pass (RSVP, ScrollReader, InlineReaderPageViewController ×2, RabbitHoleLayerViewController ×2) — combines a dedup and a dead-code removal in one mechanical change. See §2.1 Cluster 4, §2.5.
5. **[S] Batch dead-code/over-exposure sweep**: dead `chromeSave`/`isSaved` (spans 2 files), dead `SplitWebOverlayViewController` init params (`lineHeight`/`topHalf`/`bottomHalf`/`cutY`), dead `onClose`, dead `RabbitHoleReaderViewController.rootItemID` (+ fix its stale doc comment), dead `ReadingHeuristics.hasDigit`, dead `.highlight`/`.original` switch arms (3 files), and the 5 over-exposed-`public` internal helpers (`RSVPEngine.makeWord`, `WordSplitter.hyphenSplit`/`hardWrap`, `PaywallUnlockRules.expandAlternations`/`expansionLimit`, `RabbitHoleLayout.visibleAncestors`/`cardFrame`, `RabbitHoleLayerViewController.lineText(for:)`). All independently verified dead/over-exposed; batchable as one low-risk commit. See §2.5.
6. **[L] Investigate consolidating `LinkRSVPPreview.swift`'s RSVP playback engine with `RSVPViewController`'s.** The largest duplication surface in the audit by volume (word-timer/skip/ORP-render/audio-sync, near method-for-method) — highest long-term payoff but genuinely needs careful behavior-preserving design since the two evolved independently and the preview has extra constraints (floating card, drag-to-scrub). See §2.3(a).
7. **[M] Fix RSVPViewController's three self-contained duplication patterns**, which double as the god-method extraction seams: centralize play/pause glyph sync on `isPlaying.didSet` (removes 4 copies), extract the mode-dispatch triad into one helper (removes 3 copies), extract a `render(at:highlightWord:)` helper for showWord/showChunk routing (removes 4 of 5 copies). This directly shrinks `configureForReuse`/`play`/`skip(by:)`/the delegate extensions. See §2.3(d-f), §2.4.
8. **[M] Share a `FinishedReadingTracker` helper and the 0.5pt-debounce chrome-inset pattern between RSVP and ScrollReader.** Both are independently-written versions of the same state machine/property pattern; low risk, mirrors the already-shared `ReaderResumePositionResolver` precedent. See §2.3(b-c).
9. **[L] Close the test-coverage gap on the highest-complexity, zero/near-zero-covered types**: `RabbitHoleReaderViewController` (zero tests for the whole dive/pop/persist/chrome file), `LinkRSVPPreviewInteraction`/`ViewController`/`ArticleRSVPPreviewSession` (only pure gesture-policy tested), `SpeechController` (only a static filter tested), `InlineReaderEclipseTransition`'s actual animation code, and `WebArchiveCapturer` (no test file at all). These are exactly the files this audit flags as most structurally complex — a refactor of any of them currently has no automated safety net. See §3.
10. **[S] Comment-hygiene pass** (6 flagged rewrites/deletions in §2.6, plus collapsing the 7-site `.highlight`-retirement repetition to the one enum-level doc comment once the dead switch arms from item 5 are removed).

Deliberately not ranked (out of this audit's scope per its own criteria, but worth flagging to whoever owns the adjacent files): the `ArchiveWebReaderViewController` presenter-wiring duplication (§2.1 Cluster 5) and the `ArticleTextRenderer` vs. `ImageDownsampling` duplication (§2.3(i)) both have their fix surface partly or wholly outside `LunaReaderUI`/`LunaArchiveReader` ownership boundaries as scoped here.
