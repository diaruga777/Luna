# Wave 3C — shared carousel-host skeleton, archive-unlock flow, app-shell extractions

Read `PLAN.md` hard rules, `audits/app-shell.md` §2.2-2.4, and
`audits/downloader-media.md` §2.3A first. Waves 2E/3A/3B have landed — work from HEAD.
Files: `Luna/Reader/ArticleCardsViewController.swift`,
`Luna/Downloader/SavedMediaCardsViewController.swift`,
`Luna/ReadingList/ReadingListViewController.swift`, `Luna/CatchUp/*`, one new
LunaArchiveReader file, new app-shell files. One commit per item.

## 1. `ArchiveUnlockFlow` (kills the triplication — app-shell audit top-10 #1)

New file `LunaLibraries/Sources/LunaArchiveReader/ArchiveUnlockFlow.swift`:

```swift
public enum ArchiveUnlockFlow {
    /// Presents the archive-unlock web reader for `item`, wired for the standard
    /// close / open-in-browser / extracted outcomes. On successful extraction the
    /// sheet is dismissed and `onUnlocked` runs with the refreshed item.
    public static func present(
        item: ReadingListItem,
        articleURL: URL,
        store: ReadingListStore,
        from presenter: UIViewController,
        modalPresentationStyle: UIModalPresentationStyle = .automatic,
        onUnlocked: @escaping (ReadingListItem) -> Void
    )
}
```

Derive the exact body from the three existing copies
(`ReadingListViewController.presentArchiveReader`, `ArticleCardsViewController
.presentArchiveReader`, `CatchUpViewController.presentUnlock`) — they are near-identical
apart from presentation style (CatchUp: `.fullScreen`) and the success tail (reopen in
reader vs `reloadCurrentCard()`), which the parameters above carry. If the copies
diverge anywhere else, parameterize rather than pick a winner. All three call sites
adopt; the `onClose`/`onOpenInBrowser`/`onExtracted` closures on
`ArchiveWebReaderViewController` itself stay (per-presentation one-shot config — correct
pattern). Extension-side users (`ShareSurfaceDriver`, `ShareReaderViewController`) keep
their own wiring (different host constraints) unless adoption is trivially clean.

## 2. `ReaderCardContentDelegate` (app-shell audit §2.1)

The 4-closure cluster on `ReaderCardContentViewController`
(`onImmersionChange`/`onReaderReady`/`onInlineReaderChange`/
`inlineReaderCardFrameInWindowProvider`) → one protocol:

```swift
protocol ReaderCardContentDelegate: AnyObject {
    func readerCard(_ card: ReaderCardContentViewController, didChangeImmersion immersed: Bool)
    func readerCardDidBecomeReady(_ card: ReaderCardContentViewController)
    func readerCard(_ card: ReaderCardContentViewController, inlineReaderDidChange isPresented: Bool)
    func readerCardInlineFrameInWindow(_ card: ReaderCardContentViewController) -> CGRect?
}
```
(match real payloads). Conformer: `ArticleCardsViewController`.

## 3. `ScrollDirectionImmersionTracker` (app-shell audit top-10 #6)

Extract `ReaderCardContentViewController`'s generic scroll-direction machinery
(`observeReaderScrollViews`/`handleOffsetChange`/`scrollRuns` + the recursive
`rsvpControllers`/`scrollViews` walks) into a standalone app-shell type with inputs
(root view / observed scroll views) and a single `onImmersionChange`-style output
(closure here is fine — it's a single-signal utility, not a component boundary). The
directional-accumulator algorithm and its documented re-entrancy guard move verbatim.
This becomes unit-testable with synthetic offsets — Wave 4 adds those tests.

## 4. `CardCarouselHostViewController` (the ~150-200-line duplication —
downloader audit §2.3A, items 1,2,3,4,7,8 fully + 5,6 as template hooks)

New app-shell base class (new file `Luna/CardCarouselHost/CardCarouselHostViewController.swift`,
picked up by all three app targets via the synchronized group). Contract:

```swift
class CardCarouselHostViewController: UIViewController {
    let carousel: CardCarouselViewController          // created + mounted by the base
    // Shared chrome
    func configureBottomButton(_ button: UIButton, symbol: String, action: Selector, accessibilityLabel: String)
    func mountBottomControls(leading: UIButton, trailing: UIButton)   // 12pt insets, −26 bottom, 44×44
    func applyCarouselTopInset(_ inset: CGFloat)
    // Pasteboard-offset index math
    var hasLeadingPasteboardCard: Bool { get }        // subclass supplies
    var cardOffset: Int { get }                       // derived
    func itemIndex(forCarouselIndex index: Int, itemCount: Int) -> Int?
    // Fingerprint reload skeleton (template method)
    func reloadFromStore()                            // subclass builds fingerprints + items; base
                                                      // handles unchanged-bail, centering capture,
                                                      // carousel.reloadData, empty-state toggle
    // Pasteboard polling skeleton (guard changeCount / capture / async detect / re-check / reload)
    func refreshPasteboardURL(detect: …)              // payload-specific detection stays in subclasses
    // Shared empty state
    func makeEmptyStateView(symbol: String, title: String, subtitle: String) -> UIView
    @objc func settingsTapped()                       // push SettingsViewController()
}
```

Shape the final API from what the two hosts actually share — the audit's item list is
the source of truth; where the two diverge (Downloader's
`pendingPasteboardDownloadURLString` handling, `updateShareButton()`, Reader's extra
chrome-row top-inset), the divergence stays in the subclass via override points. Both
subclasses must end behaviorally identical to today — this is the highest-risk item in
the wave; prefer hooks over cleverness, and if a piece resists clean sharing (e.g. the
reload skeleton), share the smaller pieces and leave that one duplicated with a note.

## 5. `ReadingListViewController` extractions (app-shell audit §2.4 seams)

In this order, one commit each:
- **`PasteboardSuggestionController`** — the `:324-472` region (3 pasteboard vars +
  evaluate/save/preview/drop/scheduleReload), callbacks `onChange`/`onOpenTransient`
  (single-signal utility seams; closures acceptable) or a small delegate if ≥3 signals.
- **`ReadingListRowMenuFactory`** — pure `menu(for item: ReadingListItem, actions: RowMenuActions) -> UIMenu`
  where `RowMenuActions` bundles the handler closures; moves the ~130-line
  `rowMenu(for:at:)` policy out of the VC and makes it unit-testable (Wave 4 adds tests).
- **`ReadingListGroupBuilder`** — `buildGroups(items:filter:surface:pasteboardRow:)` as a
  pure type (audit: already a pure function of its inputs).
Leave the filter bar and table-header builder in place (diminishing returns — note as
deferred in your report).

## 6. `CatchUpCardBodyFactory` (app-shell audit §2.2/§2.4)

Extract `CatchUpViewController.populate(_:with:)`'s three inline card-body constructions
into a factory returning `(body: UIView, bodyTop: NSLayoutYAxisAnchor)` per the audit's
sketch. Small; keeps the VC ignorant of body-kind layout rules.

## 7. `makeToggle` fold-in (app-shell audit top-10 #9)

Move `AutoSendBySourceScreen`'s private closure-based `makeToggle(isOn:onChange:)` into
the shared `UITableViewController` extension in `SettingsViewController.swift` alongside
the Selector-based one; delete the private duplicate.

Verification: build-for-testing per commit; at wave end run
`-only-testing:LunaTests/CatchUpAndPriceScreenTests -only-testing:LunaTests/ReadingListDiffTests -only-testing:LunaTests/ReaderScreenTests -only-testing:LunaTests/SourceBadgeTests -only-testing:LunaTests/ArticleScrubPreviewTextTests -only-testing:LunaTests/InteropSettingsTests`.
The two carousel hosts have little direct coverage (that's why Wave 4 exists) — be extra
conservative on item 4; snapshot diffs anywhere = fix code, never PNGs.
