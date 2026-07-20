# Wave 1 — mechanical sweep: dead code, over-exposure, comment hygiene, doc fixes

Read `PLAN.md` hard rules first. Everything here was grep-verified by the audits, but
**re-verify each deletion with your own repo-wide grep** (exclude `build/`, `.claude/`,
`.git`) immediately before deleting — the tree may have moved. If a grep now shows a
caller, skip the item and note it in your report.

Do NOT touch `LunaSocialUI/OnboardingAnimationView.swift` (Wave 2D owns that file).

Commit structure: one commit per numbered group below.

## 1. Dead code — design system (`audits/design-system.md` §2.5)

- Delete `CardCarouselViewController.onImmersionChanged` (decl + fire site).
- Delete public `isSoundMuted` getter and `setSoundMuted(_:)`; keep the internal mute
  machinery (button + hardware-volume auto-unmute) exactly as is.
- Delete `DownsampledImageLoader.cachedImage(path:pointSize:scale:)` and its test
  case(s) in `LunaTests/DownsampledImageLoaderTests.swift` (keep the `load` tests).
- `GlassStyle.solidButtonFill` → `private`.

## 2. Dead code — reader stack (`audits/reader-ui.md` §2.5)

- Delete the plain `onLinkActivated` closure on `RSVPViewController`,
  `ScrollReaderViewController`, `InlineReaderPageViewController` (zero setters anywhere).
  At each "point-or-plain" fallback site (RSVP:640-647, Scroll:1185-1188, InlinePage ×2,
  RabbitHoleLayer ×2) simplify to a direct `onLinkActivatedAtPoint` call. (Wave 3A later
  converts these to delegates; the simplification here still pays for itself.)
- Delete dead chrome-save surface: `SplitWebOverlayViewController.chromeSave()` (empty),
  `RabbitHoleReaderViewController.chromeSave` impl, and `ReaderChromeState.isSaved`
  (writers exist but zero readers; update the two writers and the one chrome host,
  `ArticleCardsViewController`, accordingly).
- Delete `SplitWebOverlayViewController.onClose` (never assigned; distinct from
  `ArchiveWebReaderViewController.onClose`, which is live).
- Remove `SplitWebOverlayViewController.init` params `lineHeight`/`topHalf`/`bottomHalf`
  (every call site passes `0, nil, nil`) and make `sourcePoint` non-optional, dropping
  the unreachable `cutY` fallback (every call site passes non-nil). Update all 6 call
  sites incl. `LunaTests/InlineReaderTabMetricsTests.swift`; fix the init doc comment.
- Delete `RabbitHoleReaderViewController.rootItemID` (stale doc claims the mini player
  uses it; the real lookup is `containsReaderItem(withID:)`).
- Delete dead `.highlight`/`.original` switch arms in `RabbitHoleLayerViewController`
  (:691, :836) and dead `.highlight` arms in `ReaderViewController` (:247, :372) and
  `InlineReaderPageViewController` (:69, :327). Keep the `ReaderMode.highlight` enum case
  itself (needed to decode old persisted values) — the retirement story stays documented
  ONCE, on the enum in `LunaModels/ReadingListItem.swift`; delete the repeated
  explanations at the now-removed arms.
- Delete `ReadingHeuristics.hasDigit(_:)` (zero callers; `difficultyFactor` inlines the
  same check).
- Over-exposure → `private` (or `internal` where same-module callers exist):
  `RSVPEngine.makeWord`, `WordSplitter.hyphenSplit`/`hardWrap`,
  `PaywallUnlockRules.expandAlternations`/`expansionLimit`,
  `RabbitHoleLayout.visibleAncestors`/`cardFrame` (verify tests only call `placement`),
  `RabbitHoleLayerViewController.lineText(for:)`.
- Delete the empty `LunaLibraries/Sources/LunaContentRendering/` directory (zero files,
  not declared in Package.swift).

## 3. Dead code — app shell (`audits/app-shell.md` §2.5)

- Delete `InstalledAppMarkers.key(for:)`; preserve the raw-key convention it documented
  as a doc comment on the enum itself.
- Delete `ActionHostViewController` in `Luna/UITestScreen.swift` (zero instantiations;
  `PresentingHostViewController` above it is live — don't confuse them).
- `ReadingListViewController.configureItemCell(_:for:)`: if your grep confirms only
  same-file callers, make it `private`. `open(_:presenter:transitionSourceView:)` stays
  non-private (SceneDelegate + tests call it).

## 4. Dead code — media/audio/ingest

- `SavedMediaStore.item(id:)`: delete; rewrite its three `SavedMediaStoreTests` call
  sites to `items().first(where: { $0.id == … })` (`audits/downloader-media.md` §2.5).
- `ArticleAudioEngine.stop()` + the matching `ArticleAudioEngineControlling.stop()`
  requirement + fake conformances: delete (`audits/audio.md` §2.5). Careful:
  `ArticleAudioEngineTests` is environment-fragile — only touch it to delete tests of the
  removed method; do not restructure it.
- `AudioScriptStore.remove(forContentFileName:)`: delete + its test-only caller.
- `AudioPlaybackHandoff.wordIndex`/`.elapsed`: delete ONLY if you verify they are neither
  read in production NOR part of a persisted/serialized payload whose shape must survive
  (if they're encoded to disk or across processes, leave them and note it).
- Ingest 12-item sweep (`audits/ingest-pipeline.md` §2.4 has the exact list + greps):
  dead accessors/method, the 3 dead imports (`PlatformModule.swift` UIKit,
  `ArticleFetcher.swift` LunaFetch, `ReadingListStore.swift` LunaURLClassification), and
  the 2 vestigial `Package.swift` dependency edges those imports justified (only remove
  the edge if nothing else in the target imports that module — verify with grep).
  **Decoded-but-unconsumed JSON fields: remove ONLY from transient fetch/parse response
  structs. If the field lives on a model that is re-encoded to disk (`readingList.json`,
  `jobs.json`, `savedMedia.json`, etc.), removing it would drop user data on the next
  write — leave those and note them.**

## 5. Comment hygiene — apply the audits' exact rewrites

Each audit's §2.6 lists items with concrete rewrites; apply them verbatim (or with
lighter touch if the surrounding code changed in groups 1-4):

- `audits/design-system.md` §2.6 — 4 items (`NavHeaderBar.swift` ×2 "Task 3",
  `GlassStyle.swift:97-102` duplicated clause, `MoonHorizonProgress.swift:120-123`).
- `audits/reader-ui.md` §2.6 — 6 items (ReaderViewController:186, ScrollReader:551,
  LinkRSVPPreview:309, RabbitHoleLayer:735/:829/:805).
- `audits/app-shell.md` §2.6 — stale "search screen" references
  (ReadingListViewController:1278/:1388/:1425) + `ArticleCardsViewController.swift:149`.
- `audits/downloader-media.md` §2.6 — 2 items (LiveMediaDownloadManager:271-273,
  SocialMediaResolver:60-64).
- `audits/audio.md` §2.6 — 3 items (NowPlayingCoordinator:42-55, AudioScript:8-18,
  AudioSettings:12-13).
- `audits/ingest-pipeline.md` §2.5 — 13 items incl. the factual error in
  `SiteUnlockRules.swift:14-15` and the stale `BypassGateTests` reference in
  `BypassGate.swift:20`.
- `audits/share-price-intents.md` §7 — 9 one-line items.
- `audits/mail-social.md` — `EmailLoginLoadingCover.swift:9`, `EmailLoginFlow.swift:246`,
  and the dangling `SocialMessageCenter.ingestHandler` mentions in
  `AudioPlaybackWiring.swift:22` / `ReaderAudioLauncher.swift:10` (the type doesn't
  exist; reword to describe the wiring that actually exists).

Everything the audits explicitly cleared as "present-tense design rationale" stays.

## 6. Verification

`xcodebuild build-for-testing` (PLAN.md rule 4) after each commit group. Additionally run
the directly-affected test classes once at the end of the wave:
`-only-testing:LunaTests/DownsampledImageLoaderTests -only-testing:LunaTests/SavedMediaStoreTests -only-testing:LunaTests/InlineReaderTabMetricsTests -only-testing:LunaTests/ReadingHeuristicsTests -only-testing:LunaTests/RabbitHoleLayoutTests`
(needs a booted iOS 26.x sim; see CLAUDE.md recipe).

Report: items completed, items skipped (with the grep that showed a live caller), and
anything ambiguous.
