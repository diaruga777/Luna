# Rabbit-hole dive/pop/chrome/tab animation verification (e987747c..HEAD)

**Verdict: NO REGRESSIONS.** Every dive/pop/chrome/tab-strip animation present at
`e987747c` (pre-refactor) is present, byte-for-byte identical in timing/curve/constant,
at `HEAD`. The refactor (Waves 1 / 3A / 3B, i.e. commits `792529d2` through `5901c831`)
is a pure closure→delegate / dead-code-removal / class-split mechanical transform. No
animation code, duration, curve, spring constant, or call-site wiring order changed.

## Method

Read `RabbitHoleReaderViewController.swift`, `RabbitHoleLayerViewController.swift`,
`SplitWebOverlayViewController.swift`, `InlineReaderEclipseTransition.swift`,
`InlineReaderPageViewController.swift`, `CardSurfaceView.swift`, `CarouselCardView.swift`
in full at HEAD, then diffed each against `e987747c`, then diffed the intervening
commits individually (`792529d2`, `1b74bc9d`, `79ef7cef`, `e31eb5a2`, `8b1c31f7`,
`81ae4c3b`, `7a7c4d21`, `f5de42e6`, `5901c831`) and traced every closure→delegate
rewiring back to its original fire-site to confirm identical call moments and
arguments. Also checked all call sites of `SplitWebOverlayViewController.init` (4 at
`e987747c`: `RabbitHoleReaderViewController`, `ScrollReaderViewController`,
`RSVPViewController`, `Luna/UITestScreen.swift`) and the carousel-host consumer
(`Luna/Reader/ArticleCardsViewController.swift`'s `ReaderCardContentViewController`).

## The three dive paths

**(a) `presentInlineReader` → `SplitWebOverlayViewController` (eclipse).** Unchanged
choreography: `InlineReaderEclipseAnimator`/`InlineReaderEclipseScene` (forward/reverse
keyframe timings, `Self.duration = CardEclipseTransition.duration`, the 0.66/0.34 split,
corona/flare keyframe fractions, reduce-motion fallback) — zero lines of animation code
touched, only a doc-comment cross-reference added and `CarouselCardView.cornerRadius` →
`CardSurfaceView.cornerRadius` (same value, 22pt, since `CardSurfaceView` is
`CarouselCardView`'s new superclass — see below).

**(b) `pushLayer`/`popToLayer` + `applyFocus` (persistent layer stack).**
`applyFocus()` (`RabbitHoleReaderViewController.swift:286-302`) sets `frame`/`zPosition`/
`alpha`/depth/chrome directly with no `UIView.animate` — confirmed identical, line for
line, at `e987747c` (only comment wording changed: "onRootBack" → "delegate"). This
instant-snap behavior is **pre-existing**, not a refactor regression: the pre-refactor
audit `refactor-plans/audits/reader-ui.md` §2.7 (lines 528-531, 210) documents this
exact fact ("`applyFocus()`... has no bespoke animation at all... snapping the new/
previous layer into place instantly"), and I independently verified `e987747c`'s
`applyFocus()` body is textually identical to HEAD's. The only animated call to
`applyFocus()` in both versions is inside `viewWillTransition(to:with:)` (a system
rotation coordinator animation), also unchanged.

**(c) The overlay's inner tab push/pop** (`InlineReaderEclipseScene` inner transitions
+ `rebuildTabs` spring). All constants identical at HEAD vs. `e987747c`:
- reflow crossfade: `duration: 0.3`, `.curveEaseInOut, .beginFromCurrentState`
- new-tab insertion spring: `duration: 0.38, usingSpringWithDamping: 0.82,
  initialSpringVelocity: 0.55`
- outgoing-tab retreat: `duration: 0.18, .curveEaseIn, .beginFromCurrentState`
- `RabbitHoleLayout.swift`'s `cardFrame`/`visibleAncestors` math: identical (only
  `public` → internal visibility narrowed, no logic change)

## Verified "verify every call site" items from the task

**`sourcePoint` (Wave 1, dropped `lineHeight`/`topHalf`/`bottomHalf`/`cutY`).** These
four params were already dead at `e987747c`: `topHalf`/`bottomHalf`/`lineHeight` were
never read anywhere in the body; `cutY` only fed a fallback
(`sourcePoint ?? CGPoint(x: ..., y: cutY)`) for when `sourcePoint` was `nil`. All 4
real call sites at `e987747c` (`RabbitHoleReaderViewController`,
`ScrollReaderViewController.openSplit`, `RSVPViewController.activateLink`,
`Luna/UITestScreen.swift`'s `.readerNested` fixture) always passed a concrete
`sourcePoint`, never `nil` — so the fallback path was unreachable and making the
parameter non-optional dropped zero behavior. Confirmed commit `792529d2`'s own
message states this ("the unreachable cutY fallback (every call site already passes a
non-nil sourcePoint)") and independently re-verified by reading all 4 call sites at
both commits.

**`chromeSave`/`isSaved` (Wave 1).** Confirmed dead at `e987747c`: no chrome host ever
called `chromeSave()` or rendered a Save affordance from `ReaderChromeState.isSaved`
(`SplitWebOverlayViewController.chromeSave()` was an empty `{}` stub even before
removal). No other chrome behavior was swept out alongside it — `chromeSetMode`,
`chromeToggleAudio`, `chromeShare`, `chromeBack` are all present, unchanged, at HEAD.

**Coordinator delegate rewiring (Wave 3A, 5 closures → `presentationCoordinator`).**
Traced each of the 5 old closures (`onOpen`, `onChromeStateChanged`,
`onDismissalTransitionWillBegin`, `onDismissalTransitionDidCancel`, `onDismiss`) to its
new call site inside `SplitWebOverlayViewController` itself:
- `onOpen` → `transitionWillOpen()` now calls `presentationCoordinator?.inlineReaderWillPresent(self)` directly (same site, same haptic/log line before it)
- `onChromeStateChanged` → `notifyChromeStateChanged()` now calls the same method
- `onDismissalTransitionWillBegin` → reverse animator's `onTransitionStart` now calls `presentationCoordinator?.inlineReaderWillDismiss(self)` (the old code *also* called `onClose?()` first, but `onClose` was never assigned at any of the 4 call sites at `e987747c` — confirmed by `git grep`; dead, so dropping it is a no-op)
- `onDismissalTransitionDidCancel` → `presentationDismissalDidCancel()` now calls `presentationCoordinator?.inlineReaderDismissalDidCancel(self)`, same call site (`InlineReaderPresentationController.dismissalTransitionDidEnd`'s cancel branch)
- `onDismiss` → `presentationDidDismiss()` now calls `presentationCoordinator?.inlineReaderDidDismiss(self)` directly after the existing `onDismiss?()` one-shot hook (still present, still used by `ScrollReaderViewController.openSplit` to `restoreScroll`), same call site
- Cancel path verified: `InlineReaderPresentationController.dismissalTransitionDidEnd(_:)` unchanged — `completed == false` still routes to `presentationDismissalDidCancel()`, `completed == true` still routes to `presentationDidDismiss()`.

All 4 call sites (`RabbitHoleReaderViewController.presentInlineReader`,
`ScrollReaderViewController.openSplit`, `RSVPViewController.activateLink`,
`Luna/UITestScreen.swift`) now just set `overlay.presentationCoordinator = coordinator`
(ScrollReader additionally keeps its own `overlay.onDismiss = { self?.restoreScroll(...) }`
one-shot) — confirmed at HEAD this produces the identical sequence of coordinator calls
at the identical moments as the 5-closure wiring did at `e987747c`.

**`RabbitHoleReaderDelegate` (readerContentHierarchyDidChange/readerRequestedRootBack,
replacing `onContentHierarchyChanged`/`onRootBack`).** Sole conformer
`ReaderCardContentViewController` (`Luna/Reader/ArticleCardsViewController.swift`,
commit `7a7c4d21`) — its delegate methods' bodies are the old closures' bodies moved
verbatim, including the `DispatchQueue.main.async` re-sweep-for-scroll-views timing and
the `isCentered` guard before `onImmersionChange?(false, true)`/`onReaderReady?(...)`.
The carousel-chrome fade this ultimately drives —
`carousel.setImmersed(immersed, extendsCard:, animated: true)`, still a 0.32s
`.curveEaseInOut` animation in `CardCarouselViewController.setImmersed` — is untouched
by this diff range (only later, out-of-scope carousel-host-sharing commits renamed its
sibling duration constants 0.28/0.22 → `CarouselAnimationTiming.crossfadeDuration`/
`chromeFadeDuration`, same values, unrelated to eclipse/dive/pop).

**`RabbitHoleLayerDelegate` (Wave 3, 6 closures → 1 delegate) and
`InlineReaderPageDelegate` (4 closures → 1 delegate).** Same pattern: every fire site
maps 1:1 to the corresponding delegate method, called at the same point with the same
arguments (verified `onModeChanged(mode)` → `delegate?.layer(self, didChangeMode:
mode)`, `onLinkActivated`/`onLinkActivatedAtPoint`'s "point-variant preferred, else
fallback" collapsed to always-point because in every real host both closures were
always set together — the plain-text fallback was dead, confirmed by reading
`makeLayer()`'s wiring at `e987747c`).

**`ReaderCompletionDelegate` (replacing `onFinishedReading`/`onMovedAwayFromEnd`,
commit `8b1c31f7`).** `RabbitHoleLayerViewController` now conforms directly
(`readerDidFinishReading`→`markEmbeddedItemRead()`, `readerDidMoveAwayFromEnd`→
`unmarkEmbeddedItemReadIfAutoMarked()`) instead of setting two closures per embed —
same two method bodies, same call sites in `embedReader(mode:)`.

**`SplitWebOverlay`'s card view: `CarouselCardView` → `CardSurfaceView` (Wave 3B,
commit `f5de42e6`).** `CardSurfaceView` is the exact generic-surface subset of the old
`CarouselCardView` (cornerRadius 22, glass-rim border with the same 3pt rim width and
0.75pt highlight stroke, `installContentView`, `setBorderEnabled`,
`setContentEdgeFadeHeight`, `contentContainer`) — diffed field-for-field against the
pre-split `CarouselCardView` at `e987747c` and every value matches. `CarouselCardView`
now subclasses `CardSurfaceView`, adding only the carousel-specific mute button / dim
overlay / top-leading accessory (irrelevant to the overlay, which never used them —
they existed as always-hidden/zero-alpha dead UI on the overlay's card even at
`e987747c`). `SplitWebOverlayViewController`'s two actual uses,
`cardView.setBorderEnabled(true)` and `cardView.setContentEdgeFadeHeight(28)`, are
unchanged at HEAD. No border, edge-fade, or corner-radius behavior was lost.

## Conclusion

Across all three dive paths and every closure→delegate/class-split point named in the
task, HEAD's runtime behavior is identical to `e987747c`'s. The layer-stack's
instant-snap `applyFocus()` is pre-existing (documented at `e987747c` in
`refactor-plans/audits/reader-ui.md` §2.7), not something the refactor broke. No fix is
needed.
