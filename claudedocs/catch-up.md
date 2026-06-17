# Catch-Up Cards

A Slack-inbox-style swipe-through of the reading list's **unread** items (the
functionality, not Slack's visuals — it uses the app's liquid-glass aesthetic:
`.systemGroupedBackground`, `GlassStyle.readingAccent` indigo, SF Symbols, no emoji).

## Entry

`ReadingListViewController` adds a **catch-up nav button** (`rectangle.stack`,
accent-tinted, `accessibilityLabel "Catch up"`) to `navigationItem.rightBarButtonItems`.
It **pulses + glows** (CABasicAnimation scale + shadowOpacity on its layer) when the
unread count `> catchUpPulseThreshold` (12); `updateCatchUpButton()` runs on every
`reload()`. Tapping presents `CatchUpViewController(unread:router:)` full-screen.

The queue = `store.items()` filtered to unread (`readState != .read`) AND renderable
(ready articles, or any platform/media item).

## `Clip/CatchUp/`

- **`CatchUpViewController.swift`** — orchestrator. Phases: `.cards` → (`.deletePrompt`
  if any read items) → `.done`.
  - Top bar: left (chevron on cards / `xmark` on end screens → commit + close),
    center title ("N left"), right (share current card / **Undo** on done / none on
    delete prompt).
  - Bottom buttons: Bump + Mark Read (cards) / Keep + Delete All (delete) / full-width
    Done (done). `styleButton` = filled accent for the primary action (red for Delete
    All), tinted-accent glass for the secondary.
  - Each card: a `CatchUpCardHeader` (bump date or save date, + "from <friend>"),
    then either an embedded **`ReaderViewController`** (in a `UINavigationController` so
    the mode switcher shows; `forceMode: .scroll`, `persistsModePreference: false`,
    `marksOpenedOnLoad: false`, no share/gaze) for articles, or a **`CatchUpMediaCardBody`**
    (thumbnail above text + "Tap to open") for media/link items. Media tap →
    `ReadingListViewController.openItem(_:presentingFrom:)` then mark read.
  - Actions: Bump → `store.bump(id)` (stamps `bumpDate`, moves to list top); Mark Read
    → `store.markReadState(.read, …)`; advance; at the end, the delete/done screens.
  - **Undo** restores `snapshot` (the whole list captured at entry) via
    `store.restore(_:)`. Delete-all-read is **deferred** to Done (`pendingDeleteRead`)
    so Undo can revert it; `commitAndClose()` runs `deleteAllRead()` only if pending.
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
