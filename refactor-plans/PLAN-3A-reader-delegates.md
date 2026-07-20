# Wave 3A — reader stack: closure clusters → delegates; RSVP/Scroll internal cleanup

Read `PLAN.md` hard rules and `audits/reader-ui.md` §2.1 (clusters), §2.3, §2.4 first.
Wave 1 already deleted the dead closures/params — work from current HEAD, not audit line
numbers. Files: `LunaReaderUI/*`, plus the adopting call sites in `Luna/Reader/`,
`Luna/CatchUp/`, `Luna/UITestScreen.swift`. One commit per numbered item.

Design conventions for every protocol introduced here: class-bound (`AnyObject`),
`weak var delegate`, methods named `<noun>(_ sender:, verbPhrase…)` UIKit-style, source
object always the first parameter. A protocol replaces a closure cluster ONLY — genuine
one-shot completion handlers and launch-time DI closures stay closures.

## 1. `RabbitHoleLayerDelegate` (audit Cluster 1 — 6 closures, one collaborator)

```swift
public protocol RabbitHoleLayerDelegate: AnyObject {
    func layer(_ layer: RabbitHoleLayerViewController, didActivateLink url: URL, at point: CGPoint?)
    func layerRequestedPopToHere(_ layer: RabbitHoleLayerViewController)
    func layerDidBecomeArticle(_ layer: RabbitHoleLayerViewController)
    func layer(_ layer: RabbitHoleLayerViewController, didChangeMode mode: ReaderMode)
    func layerRequestedBack(_ layer: RabbitHoleLayerViewController)
}
```
(Adjust signatures to the closures' real payloads.) Replace `onLinkActivated…AtPoint`/
`onPopToHere`/`onBecameArticle`/`onModeChanged`/`onBack` with `weak var delegate`.
Sole conformer: `RabbitHoleReaderViewController` — its `makeLayer()` drops the six
weak-capture assignments for one `layer.delegate = self`. The two direct test
constructions in `RabbitHoleStackStoreTests` don't set closures; verify they still pass.

## 2. Split-overlay presentation wiring (Cluster 2 — 5 closures × 3 identical call sites)

Replace the five forwarding closures (`onDismiss`, `onDismissalTransitionWillBegin`,
`onDismissalTransitionDidCancel`, `onOpen`, `onChromeStateChanged`) with a single
`weak var presentationCoordinator: InlineReaderPresentationCoordinating?` that the
overlay calls directly at the points where it currently fires the closures. If any
closure carries a payload the protocol lacks (e.g. chrome-state change), extend
`InlineReaderPresentationCoordinating` with the missing method — all four current
conformers must implement it (default no-op extension only if a conformer genuinely has
no behavior today).

Add ONE shared ancestor-walk helper (internal `UIViewController` extension in
`LunaReaderUI`): `var inlineReaderPresentationCoordinator: InlineReaderPresentationCoordinating?`
walking `parent`. All three creators (RSVP, ScrollReader, RabbitHoleReader) use it and
just set `overlay.presentationCoordinator = …`. This also fixes the boundary violation
(audit §2.2): `ScrollReaderViewController.openSplit` currently walks to the CONCRETE
`ReaderViewController` and calls its methods directly — after this change it goes
through the protocol like everyone else. Any `ReaderViewController` members it needed
(`inlineReaderTopEdgeInWindow` etc.) must be on the protocol.
`Luna/UITestScreen.swift`'s 3-closure subset gets the same treatment.
`InlineReaderTabMetricsTests`' dismiss-fires-once VC test must stay green.

## 3. `ReaderCompletionDelegate` (Cluster 3 — same pair, 2 reader types, 2 hosts)

```swift
public protocol ReaderCompletionDelegate: AnyObject {
    func readerDidFinishReading(_ reader: UIViewController)
    func readerDidMoveAwayFromEnd(_ reader: UIViewController)
}
```
Replace `onFinishedReading`/`onMovedAwayFromEnd` on BOTH `RSVPViewController` and
`ScrollReaderViewController` with `weak var completionDelegate:`. Adopters:
`ReaderViewController`, `RabbitHoleLayerViewController` (each currently wires the pair
twice). While here, extract the duplicated fire-once/fire-back state machine (audit
§2.3(b)) into a small shared `FinishedReadingTracker` struct used by both readers —
same edge tests per reader (scroll-ratio vs frame-index), shared bookkeeping.
`ReaderScreenTests` exercises finish/unmark heavily — green required.

## 4. `InlineReaderPageDelegate` (Cluster 6 — 4 closures, one set-site)

Fold `onLinkActivatedAtPoint`/`onBecameArticle`/`onMetadataChanged`/
`onContentScrollViewChanged` on `InlineReaderPageViewController` into one delegate
protocol; sole conformer `SplitWebOverlayViewController` (its `makePage` sets
`page.delegate = self`).

## 5. `RabbitHoleReaderDelegate` (Cluster 7 — completes the existing pattern)

`onContentHierarchyChanged`/`onRootBack` → protocol implemented by the host
(`ArticleCardsViewController`), matching the query-direction `ReaderChromeControlling`
that already exists. (3C restructures that host further; keep this change minimal.)

## 6. RSVP internal dedups (audit §2.3 d/e/f — these shrink the god methods)

- Play/pause glyph sync: one `updatePlayPauseGlyph()` driven from `isPlaying.didSet`,
  deleting the 4 manual copies.
- The `isSpeechMode / .phrases / words` dispatch triad (3 copies) → one helper.
- The showWord/showChunk routing (5 copies) → one `render(at:)` helper.
- The 0.5pt chrome-inset debounce duplicated across both readers → tiny shared helper.

## 7. God-method splits (audit §2.4 — mechanical decomposition, no logic change)

- Both readers' `configureForReuse` → `resetTransientState()` + `applyContent(…)`.
- Both readers' `viewDidLoad` → grouped `configure*` calls (remove RSVP's duplicate
  initial-state derivation already done in `init`).
- `ScrollReaderViewController.startSpeech` → two clearly-named paths (center-driven vs
  legacy `SpeechController`) instead of one early-return glue method.

## 8. Small shared pieces

- `ArticleTextRenderer.downsampledImage` → `LunaDesignSystem.ImageDownsampling.decode`
  (audit §2.3(i); the helper is synchronous, same recipe — verify identical
  maxPixelSize/scale semantics, keep the renderer's own `NSCache` keying).
- One whitespace tokenizer (audit §2.3(g)): extract the shared "split on whitespace"
  word-index tokenizer into `LunaReaderEngine` and use it from `RSVPEngine` and
  `WordMap` (byte-identical splitting; `WordMapTests`/`RSVPEngineTests` prove it).
  `AudioWordEventTokenMapping` was already rebuilt on `AudioWordIndexing` in Wave 2A —
  leave it.

## 9. Lower priority (do if the above lands clean, else report-deferred)

`LinkRSVPPreview`'s 7 boolean pause flags → one playback-state enum with lock kept
orthogonal (audit §2.4). NOT the full engine merge with `RSVPViewController` — that
stays out of scope (master plan).

Verification: build-for-testing per commit; at wave end run
`-only-testing:LunaTests/ReaderScreenTests -only-testing:LunaTests/RSVPAudioResyncTests -only-testing:LunaTests/RSVPEngineTests -only-testing:LunaTests/WordMapTests -only-testing:LunaTests/InlineReaderTabMetricsTests -only-testing:LunaTests/RabbitHoleStackStoreTests -only-testing:LunaTests/RabbitHoleLayoutTests -only-testing:LunaTests/ChunkPlannerTests -only-testing:LunaTests/ArticleTextRendererProgressiveTests -only-testing:LunaTests/LinkRSVPPreviewGesturePolicyTests`.
Snapshot diffs = behavior change: fix code, never PNGs.
