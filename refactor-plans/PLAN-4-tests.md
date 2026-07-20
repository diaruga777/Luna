# Wave 4 — restore deleted test coverage + cover newly extracted logic

Read `PLAN.md` hard rules, `audits/share-price-intents.md` §0 (the `97833a34` test-
deletion finding) and `audits/mail-social.md` finding on the same commit. This wave adds
tests only — production code changes are limited to test seams (and the
`ShareViewController.javaScriptResult` visibility decision below). One commit per group.

## 1. Restore tests deleted by commit `97833a34` (2026-07-07)

Recover each with `git show 97833a34~1:LunaTests/<name>.swift`, then ADAPT to today's
APIs (Waves 1-3 changed shapes: delegates instead of closures, moved types). Drop test
cases for features that genuinely no longer exist (Boox, the removed YouTube module);
everything else should be made to pass against current behavior — if a restored test
fails, first suspect the restoration/adaptation, then check whether one of OUR waves
changed behavior (that's a refactor bug: fix the code); only then consider that `main`'s
behavior legitimately changed between July 7 and now (adjust the assertion and say so in
your report).

Priority order (from the audits):
1. `ReadingListSectioningTests` (46 cases — section assignment, catch-up queue, dot
   logic; note CLAUDE.md still cites this file). Mind the setUp detail CLAUDE.md
   documents (dismissing the voice-catch-up flag).
2. A behavioral `ShareSurfaceDriverTests` (the surviving
   `ShareSurfaceDriverInteropTests` covers only the interop gate). If the restored tests
   need `ShareViewController.javaScriptResult`, keep it `public`; if not, tighten it to
   `internal` in the same commit.
3. `ReadingListSubtitleTests` (22 cases, currently zero coverage).
4. `SurfaceParityTests` (cross-app-surface divergence — exactly the regression class
   this whole refactor could introduce).
5. `ArticleSendCoordinatorTests`, `SourceSendSettingsTests`, `SavePressPolicyTests`
   (live retry/backoff/fan-out/gating logic with zero tests today).

`LunaTests/` files are picked up by the test target automatically (synchronized group) —
verify with a build; if a file doesn't compile into the target, check
`Luna.xcodeproj` membership before assuming otherwise.

## 2. New tests for logic extracted in Waves 2-3

- `ScrollDirectionImmersionTracker` — synthetic scroll-offset sequences: direction
  accumulation, threshold crossing, the re-entrancy guard.
- `ReadingListGroupBuilder` — pure grouping over fixture items × filters × surfaces.
- `ReadingListRowMenuFactory` — action set per item shape (priceTracker / shareable /
  platform / read states).
- `MediaMuxer` — video-only passthrough, video+audio mux, both throw paths (tiny fixture
  assets generated in-test or bundled).
- `ReadingListStore` cache-coherence + skip-write-when-unchanged — the two tests
  PERF_REVIEW_PLAN items 2/3 specified but never landed (ingest audit §3).
- `SavedMediaCardsViewController` adapter logic IF cheaply reachable after 3C (storage-
  state/kind dispatch, pasteboard-offset math via the shared base) — else note the gap.

## 3. Rules

- Never re-record snapshot PNGs in this wave.
- Match existing test style (fixture helpers, `UITestFixtures`/seeded stores where the
  neighboring tests use them).
- Each restored/new file must run green locally before its commit:
  `xcodebuild test -scheme Luna -destination "platform=iOS Simulator,id=$SIM" -only-testing:LunaTests/<Class> -derivedDataPath build/dd DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`
