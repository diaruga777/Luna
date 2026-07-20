# Luna structural refactor — master plan (2026-07-21)

Goal: simplify and refactor for best practices with **zero functionality change**.
Emphases (from the brief): views manage their contents independent of their container;
cross-component communication uses delegate protocols, not closure member variables;
animations structured but not over-abstracted; dead code removed; comments describe what
code *does now* (and why esoteric code exists), never what it doesn't do or used to do.

Inputs: eight part audits in `refactor-plans/audits/*.md` (every claim grep-verified).
Each execution plan below cites audit sections for file:line detail — executors must read
the cited audit sections before editing.

## Hard rules for every executor

1. **Behavior-preserving only.** If a change would alter observable behavior (different
   pixels, different matching results, different ordering, different persisted bytes), do
   NOT make it — flag it in your report instead. Bug *fixes* count as behavior changes
   unless the plan explicitly authorizes one.
2. **Public API of `LunaLibraries` may change** (it's an internal package) but every
   in-repo caller — three app targets, share/action/safari extensions, both clips, the
   Live Activity widget, and `LunaTests` — must be updated in the same commit and still
   compile. Grep before assuming a symbol is private to a module.
3. **Small logical commits as you go** (repo rule). One commit per numbered plan item or
   per tightly-related cluster. Never bundle unrelated changes.
4. **Compile check per commit cluster** (token-efficient testing rule — no per-commit
   full test runs):
   `xcodebuild build-for-testing -scheme Luna -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`
   The full `LunaTests` suite runs ONCE at the end (Wave 5).
5. **Comments**: write like a careful human maintainer. When touching a comment, apply the
   audit's rewrite if given. Never introduce comments narrating this refactor ("moved
   from", "extracted", "now uses"). Match surrounding density and voice.
6. Swift 5 language mode, iOS 18 deployment target, `public` + explicit `public init` for
   anything crossing a module boundary. Do not add new SwiftPM targets or dependencies.
7. Do not touch `.claude/worktrees/` (another agent's unmerged work), `build/`,
   `CODE_REVIEW_PLAN.md`, `PERF_REVIEW_PLAN.md`.

## Execution order (waves)

Waves run sequentially. Within Wave 2, the five plans touch disjoint files and MAY run in
parallel. Waves 3A→3B→3C are sequential because they share files
(`SplitWebOverlayViewController`, `ArticleCardsViewController`, `SavedMediaCardsViewController`).

| Wave | Plan file | Scope |
|---|---|---|
| 1 | `PLAN-1-mechanical.md` | Repo-wide dead code, over-exposure tightening, comment hygiene, doc fixes |
| 2 (parallel) | `PLAN-2A-audio.md` | LunaAudioPlayback + MiniPlayer dedup/structure |
| 2 (parallel) | `PLAN-2B-media-download.md` | LiveMediaDownloadManager split + dedups |
| 2 (parallel) | `PLAN-2C-ingest.md` | Ingest/classification dedups |
| 2 (parallel) | `PLAN-2D-mail-social.md` | OnboardingAnimationView + mail/social dedups |
| 2 (parallel) | `PLAN-2E-share-price.md` | Share/price dedups + delegate conversion |
| 3A | `PLAN-3A-reader-delegates.md` | Reader stack: closure clusters → delegates; RSVP internal dedups |
| 3B | `PLAN-3B-carousel.md` | CardCarousel decomposition, CarouselCardView split, indicator boundary fix |
| 3C | `PLAN-3C-hosts-appshell.md` | Shared carousel-host skeleton, archive-unlock flow, ReadingListVC extractions |
| 4 | `PLAN-4-tests.md` | Restore tests deleted by commit `97833a34`; add tests for newly extracted logic |
| 5 | (this file) | Full suite on iOS 26.x sim; fix regressions; update CLAUDE.md + claudedocs; final report |

## Cross-part API contracts (summary — details in each plan)

- **`RabbitHoleLayerDelegate`** (LunaReaderUI): replaces 6 closures on
  `RabbitHoleLayerViewController`; sole conformer `RabbitHoleReaderViewController`.
- **`ReaderCompletionDelegate`** (LunaReaderUI): `didFinishReading(_:)` /
  `didMoveAwayFromEnd(_:)`; conformers RSVP + Scroll readers; adopters
  `ReaderViewController`, `RabbitHoleLayerViewController`.
- **`InlineReaderPresentationCoordinating`** stays the host-lookup protocol; overlay
  wiring collapses into one `SplitWebOverlayViewController.connect(toCoordinatorOf:)`.
- **`ReaderCardContentDelegate`** (app shell): replaces the 4-closure cluster on
  `ReaderCardContentViewController`.
- **`CarouselScrubberViewDelegate`** (LunaDesignSystem): `scrubber(_:didPreview:)` /
  `scrubber(_:didCommit:)`.
- **`AudioPlaybackCenterDataSource`** (LunaAudioPlayback): replaces `nextItemProvider` +
  `scriptProvider` + `scriptPrefetchHandler`; one conformer in the app shell wiring.
- **`CardSurfaceView`** (LunaDesignSystem): generic bordered/edge-fading card chrome;
  `CarouselCardView: CardSurfaceView` adds carousel-only mute/dim/accessory.
- **`CardCarouselHostViewController`** (app shell base class): shared skeleton for
  `ArticleCardsViewController` + `SavedMediaCardsViewController` (bottom buttons,
  top inset, pasteboard-offset index math, fingerprint reload, empty state, settings).
- **`ArchiveUnlockFlow`** (LunaArchiveReader): one presenter for the triplicated
  archive-unlock sequence; callers supply only the on-success tail.

## Explicitly out of scope (report to user, do not change)

- The `PlatformRecognizer` vs `LunaPlatforms` host-matching **behavioral drift** (fixing
  it changes matching results). Consolidate only byte-identical logic; document the drift.
- `ReadingListItem.sharedByUsername` dead field (product decision: wire or remove).
- JSON-tree-walker determinism unification (sorted vs unsorted walk changes extraction
  winners in edge cases).
- Rabbit-hole dive/pop has no animation — flagged as possible design gap, not ours to add.
- The three eclipse transitions stay three (visual techniques genuinely differ); we add
  cross-referencing comments instead of merging (PLAN-3B).
- Full merge of `LinkRSVPPreview`'s mini RSVP engine into `RSVPViewController` (highest-
  duplication finding, but zero test coverage on the preview side makes a behavior-
  preserving merge unverifiable today; only the small shared pieces land — PLAN-2A/3A).
- Reader card pasteboard preview vs list-row preview unification (product decision).
- `.claude/worktrees/agent-a44f9578d823e01c8/` stale worktree (someone else's branch).
- Swift 6 strict concurrency; per-app dependency slimming (documented deferrals).

## Wave 5 verification

Full suite per CLAUDE.md recipe on a booted iOS 26.x simulator, `-scheme Luna`.
Expected baseline: ~929 tests green, 2 intentional skips (plus the environment-fragile
`ArticleAudioEngineTests` caveat). Snapshot tests must pass WITHOUT re-recording — a
snapshot diff means a behavior change escaped review: fix the code, never the PNG.
New/restored tests from Wave 4 must be green. Then update CLAUDE.md (stale
`SocialMessageCenter.ingestHandler` reference, `Luna/Intents/*` path, test counts) and
`claudedocs/` for any doc drift the audits flagged.
