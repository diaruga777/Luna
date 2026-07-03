# Reading-List Search

Full-screen search over saved items, combining instant string matching with
on-device semantic nearest-neighbour.

## Entry point & nav bar

`ReadingListViewController.setDefaultNavItems` (updated):
- **Top-left**: a capsule **pill** (`makeLeftPill`) holding the **settings** (gearshape) and **friends** (person.2) icons.
- **Top-right**: **add** (`+`) and **search** (magnifyingglass, `searchTapped`) — search sits where friends used to be.

`searchTapped` hosts `SearchViewController` **in place** (no modal page transition): its view is added over `nav.view` (NOT via VC containment — a strong `searchController` ref keeps it alive; `addChild` on a UINavigationController corrupts its stack → a stray back button) and **cross-faded** (`alpha` 0→1). `onExit` fades it out (`dismissSearch`); `onOpen` removes it immediately then opens the result on the list's nav. Background is `systemBackground` (black in dark mode → the "fade to black" effect).

The list's nav bar is hidden **synchronously up front** (`setNavigationBarHidden(true)` before the keyboard rises) — NOT in the fade completion. The search field becoming first responder raises the keyboard, which triggers a nav-controller relayout that would re-front the still-visible bar OVER the overlay (a dark band across the top of the results, only clearing once layout settles). Hiding it first keeps it down for the whole session; `dismissSearch`/`removeSearch` restore it.

## Key files

- `Luna/Search/SearchViewController.swift` — the UI. Bottom search field (focuses in `viewDidAppear`); an **X to its left** exits (`exitSearch` → `engine.release()` + dismiss); the field's inline **clear (x)** is `clearButtonMode = .whileEditing`. Results render in a `UITableView` ABOVE the field (table pinned top→`bar.top`; the bar pinned to `view.keyboardLayoutGuide.topAnchor` so it rides above the keyboard). Rows reuse `ReadingListItemCell`.
- `Luna/Search/ReadingListSearchEngine.swift` — `ReadingListSearching`. Two streams:
  - **String** (`stringMatches`): an in-memory `[SearchEntry]` haystack (pre-lowercased title/metadata + extracted body), built once per session in `prepare()` off-main. Pure `rank(needle:in:)` returns **title/metadata hits first, then body-only hits** (unit-tested in `ReadingListSearchEngineTests`). Instant per keystroke.
  - **Semantic** (`semanticMatches`): embeds the query via `SemanticEmbedder`, then `SemanticIndexStore.nearestItems(toVectors:threshold:excluding:limit:)`. Threshold `semanticThreshold = 0.45` (tunable; query→content cosine runs lower than the item→item sharing threshold), limit 40.
- Reuse seam: `ReadingListItemPresenting` (in SearchViewController.swift, implemented by `ReadingListViewController`) — `configureItemCell`, `open(_:presenter:)`, `searchResultMenu(for:sourceView:presenter:onChange:)`. So search rows look/behave exactly like list rows.

## Per-keystroke flow (`SearchViewController.runSearch`)

1. Bump `queryToken`. Run `stringMatches` synchronously → set `results` → reload (instant).
2. Dispatch `semanticMatches(excluding: stringResultIDs)` on a **serial** `semanticQueue` (the NL model isn't reentrant). On completion, if `queryToken` is unchanged (no newer keystroke), append the de-duped semantic hits and reload. Stale results for superseded queries are dropped by the token check.

Opening a result uses `ReadingListViewController.open(_:presenter: searchVC)` (reader pushes on the search nav; video/platform/archive present from search). Long-press / sim row-actions menu = `searchResultMenu`: **always Bump to Top**, **never Edit List**; Send to Friend / Share Link / Copy Link / Kindle / Boox / Unarchive / Delete as applicable; `onChange` re-runs the search after a mutation. Excludes eBook-share and media-to-Photos (those draw on the list itself).

## Semantic index (powers search)

See `semantic-sharing.md`. Two changes for search:
- `SemanticIndexer.scheduleRun()` runs **regardless of `SemanticSharingSettings`** (indexing powers search now; only the share *suggestion* stays gated). It embeds **all** saved items lacking vectors (`itemIDsNeedingVectors(amongAll:)`), not just shared ones, ≤20/run, off-main; `SearchViewController` kicks it on open.
- `SemanticIndexer.embeddingChunks` embeds an item's **content** — title + channel + `mediaCreatorName` + `mediaItemTitle` + article body — **never the URL** — so videos/posts/music surface on what they're about.
- `SemanticIndexStore.maxIndexedItems` raised to 2000.
