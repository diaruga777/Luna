# Catch-Up Cards

A Slack-inbox-style swipe-through of the reading list's **unread** items (the
functionality, not Slack's visuals — it uses the app's liquid-glass aesthetic:
`.systemGroupedBackground`, `GlassStyle.readingAccent` indigo, SF Symbols, no emoji).

## Entry

`ReadingListViewController` pins a **catch-up button** (`rectangle.stack`,
accent-tinted, `accessibilityLabel "Catch up"`) to the **"Reading List" large-title
row** (a nav-bar subview, trailing/bottom; re-pinned each `viewWillAppear`, removed
on disappear). A red "action needed" **dot** shows when there are unread items
(`updateCatchUpButton()` on every `reload()`); the button is hidden in edit mode.
Tapping presents `CatchUpViewController(unread:router:)` full-screen.

The queue = `store.items()` filtered to unread (`readState != .read`) AND renderable
(ready articles, or any platform/media item), sorted **oldest-first** by
`bumpDate ?? dateAdded`.

**Style**: the app's liquid-glass aesthetic — `.systemGroupedBackground` screen;
each card is a `GlassStyle.barEffect()` backdrop with rounded corners + hairline
border; the Bump / Mark Read drag labels are liquid-glass capsule pills (icon +
mixed-case text) hovering in the card's top corners. The card header (date/sender)
is centered and media/link bodies are vertically centered, leaving the corners clear
for the pills.

## `Clip/CatchUp/`

- **`CatchUpViewController.swift`** — orchestrator. Phases: `.cards` → (`.deletePrompt`
  if any read items) → `.done`.
  - Top bar: left (chevron on cards / `xmark` on end screens → commit + close),
    center title ("N left"), right (share current card / **Undo** on done / none on
    delete prompt).
  - Bottom buttons: Bump + Mark Read (cards) / Keep + Delete All|Selected (delete) /
    full-width Done (done). `styleButton` = filled accent for the primary action (red
    for delete), tinted-accent glass for the secondary.
  - Each card: a `CatchUpCardHeader` (bump date or save date, + "from <friend>"),
    then either an embedded **`ReaderViewController(inlineControlsHeader: true)`** —
    added DIRECTLY (no `UINavigationController`) so the mode switcher + audio render in
    an inline **liquid-glass** header. iOS 26 glass balloons under a rotation transform,
    so `CatchUpCardView` sets `layer.shouldRasterize` while rotating (`apply`/`performAction`,
    cleared on `springBack` completion) — the glass bakes to a bitmap at identity scale
    and the rotation just transforms that bitmap; `forceMode: .scroll`, `persistsModePreference: false`,
    `marksOpenedOnLoad: false`, no share/gaze — or a **`CatchUpMediaCardBody`**
    (thumbnail above text + "Tap to open") for media/link items. Media tap →
    `ReadingListViewController.openItem(_:presentingFrom:)` then mark read.
  - Actions: Bump → `store.bump(id)` (stamps `bumpDate`, moves to list top); Mark Read
    → `store.markReadState(.read, …)`; advance; at the end, the delete/done screens.
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
  the delete/done screens), `CatchUpCardHeader`, `CatchUpMediaCardBody`.

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
