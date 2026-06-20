# Catch-Up Cards

A Slack-inbox-style swipe-through of the reading list's **unread** items (the
functionality, not Slack's visuals — it uses the app's liquid-glass aesthetic:
`.systemGroupedBackground`, `GlassStyle.readingAccent` indigo, SF Symbols, no emoji).

## Entry

`ReadingListViewController` pins a **catch-up button** (`rectangle.stack`,
accent-tinted, `accessibilityLabel "Catch up"`) to the **"Reading List" large-title
row** (a nav-bar subview, trailing/bottom; re-pinned each `viewWillAppear`, removed
on disappear). A red "action needed" **dot** shows when there are 10+ unread items OR
whenever there's an unarchived **locked** save (regardless of count;
`updateCatchUpButton()` on every `reload()`); the button is hidden in edit mode.
Tapping presents `CatchUpViewController(unread:router:)` full-screen.

**Locked cards.** A `.needsCaptcha` (paywalled, awaiting archive unlock) reader is now
included in the queue and shown as a **locked card** (lock glyph + title + hint). Its
left action is **Unlock** (not Keep) — `CatchUpCardView.isLocked` swaps the left
zone/badge to `.unlock` and disables Bump; right is still Archive. Unlock presents the
in-app `ArchiveWebReaderViewController` (with an "Open in Safari" escape hatch); on
success the item flips to `.ready` and the SAME card is rebuilt in place
(`reloadCurrentCard`), no advance; on cancel the locked card stays.

The queue = `store.items()` filtered to unread (`readState != .read`) AND renderable
(ready articles, or any platform/media item), sorted **oldest-first** by
`bumpDate ?? dateAdded`.

**Style**: the app's liquid-glass aesthetic — `.systemGroupedBackground` screen;
each card is a `GlassStyle.barEffect()` backdrop with rounded corners + hairline
border; the Keep / Bump / Archive drag labels are liquid-glass capsule pills (icon +
mixed-case text) hovering in the card's top corners, with distinct tints (Keep gray,
Bump indigo accent, Archive green). The card header (date/sender)
is centered and media/link bodies are vertically centered, leaving the corners clear
for the pills.

## `Clip/CatchUp/`

- **`CatchUpViewController.swift`** — orchestrator. Phases: `.cards` → (`.deletePrompt`
  if any read items) → `.done`.
  - Top bar: left (chevron on cards / `xmark` on end screens → commit + close),
    center title ("N left"), right (share current card / **Undo** on done / none on
    delete prompt).
  - Card gestures (`CatchUpCardView`, action `.keep/.bump/.archive`): swipe RIGHT =
    **Archive** (mark read); swipe LEFT = **Keep** (no-op, advance); swipe LEFT then UP
    = **Bump**. Left-then-up is used for Bump so a plain vertical drag still scrolls the
    embedded reader (`gestureRecognizerShouldBegin` only claims horizontal-start drags).
  - Bottom buttons: Keep + Archive (cards) / Keep + Delete All|Selected (delete) /
    full-width Done (done). `styleButton` = filled accent for the primary action (red
    for delete), tinted-accent glass for the secondary.
  - Each card is either an embedded **`ReaderViewController(inlineControlsHeader: true,
    inlineHeaderSubtitle:)`** — added DIRECTLY (no `UINavigationController`) where the
    card's date/sender (`CatchUpCardHeader.text(for:)`) is folded into the reader's
    SINGLE inline **liquid-glass** header above the mode switcher + audio (one
    continuous header, no separate strip / divider seam) — OR a media card which keeps
    a standalone `CatchUpCardHeader` (bump/save date + "from <friend>") strip above a
    `CatchUpMediaCardBody`. iOS 26 glass balloons under a rotation transform,
    so `CatchUpCardView` sets `layer.shouldRasterize` while rotating (`apply`/`performAction`,
    cleared on `springBack` completion) — the glass bakes to a bitmap at identity scale
    and the rotation just transforms that bitmap (reader uses `forceMode: .scroll`,
    `persistsModePreference: false`, `marksOpenedOnLoad: false`, no share/gaze). The
    media card's body is tapped to open → `ReadingListViewController.openItem(_:presentingFrom:)`
    then mark read.
  - Actions: Keep → no-op; Bump → `store.bump(id)` (stamps `bumpDate`, moves to list
    top); Archive → `store.markReadState(.read, …)`; advance; at the end, the delete/done
    screens (the delete screen offers to clear the items archived this session).
  - **Delete screen** = `CatchUpDeleteReadView`: a prompt label on top + a multi-select
    table of the read items (radios, all selected by default; tap toggles, no row
    actions). The prompt/button flip "Delete All"↔"Delete Selected" via
    `onSelectionChanged`; the SELECTED ids are deleted, **deferred** to Done
    (`pendingDeleteIDs`) so **Undo** (which restores the entry `snapshot` via
    `store.restore(_:)`) can revert it.
  - Simulator-only `addSimulatorSwipeHookIfNeeded` + `CatchUpCardView.simulatorHoldSwipe`
    hold a partial swipe so the rotated state is inspectable without a drag gesture.
- **`CatchUpCardView.swift`** — swipeable card: a horizontal pan rotates + tints the
  card and fades the corner action label in (left = BUMP, right = READ); past 30% width
  or a fast flick it flies off and reports the action. `gestureRecognizerShouldBegin`
  only claims horizontal drags so the article's vertical scroll still works. The bottom
  buttons call `performAction(_:)` for the same fly-off.
- **`CatchUpSubviews.swift`** — `CatchUpMessageView` (accent SF Symbol + bold text for
  the delete/done screens), `CatchUpCardHeader`, `CatchUpMediaCardBody`,
  `CatchUpPriceTrackerCardBody`, `PriceTrackerStoreRowsView`.

**Price-tracker cards.** A non-archived, unread price tracker surfaces in the queue
(`catchUpQueue` keeps every non-`.read` non-reader item) and gets its OWN layout
(`CatchUpPriceTrackerCardBody`, no date strip — it fills the whole content area,
vertically centered): top→bottom = a **small product thumbnail** (120pt), the
**product name** (centered), a **non-tappable mini-table** of the tracked sites
(`PriceTrackerStoreRowsView`: one row per `store`, host left + price right, no chevron
/ no selection; the **current best-price** row is accent-tinted + bold via
`PriceTracker.bestPriceStoreID`), and the shared **`AlertThresholdSlider`** at the
bottom. The thumbnail is resolved the SAME way as `ReadingListItemCell` —
`PriceTracker.imageFileName` inside `store.articlesDirectory` (NOT
`item.thumbnailFileName`, which is nil for trackers — that was the missing-thumbnail
bug), falling back to a `tag`/`tag.fill` glyph. The card's slider drives the same
`alertThresholdFraction` and persists via `store.updatePriceTracker` on commit, so
editing the threshold from catch-up sticks. `CatchUpCardView.gestureRecognizer(_:shouldReceive:)`
rejects touches landing on a `UISlider` so the card swipe doesn't steal the slider drag.
The slider component is shared with the editor — see `price-tracking.md`.

## Model / store

- `ReadingListItem.bumpDate: Date?` (decodeIfPresent).
- `ReadingListStore.bump(_:)` — stamps `bumpDate = now` and moves the item to the
  front (re-sorts it to the top of the reading list).
- `ReadingListStore.restore(_:)` — overwrites the whole list (one-shot Undo).
- `ReaderViewController.marksOpenedOnLoad` — false in catch-up so previewing a card
  doesn't mark the article opened (only an explicit Mark Read changes state).

## Tested

Sim-verified via the bottom buttons (drag isn't synthesizable by the harness — see
`simulator-testing.md`): entry button, article reader card (mode switcher + scroll),
media card, Bump (re-sorts to top), Mark Read, delete-prompt screen, done screen, Undo.
The pulse triggers at >12 unread.

Snapshot coverage (`CatchUpAndPriceScreenTests`): `catchup-cards`, `catchup-mixed`,
and `catchup-price-tracker` (the tracker card — thumbnail, name, per-store mini-table,
threshold slider). `PriceTracker.bestPriceStoreID` (best-price-row selection +
deterministic tie-break) is unit-tested in `PriceTrackerTests`.
