# Reading List & Ingestion

Clip is a weblink reader: links saved from Safari (extension + intent) or pasted in-app are downloaded, stripped to readable text, and read in two reader modes.

## Key files

- `Clip/ReadingList/ReadingListItem.swift` — model. Content state: `pending → ready | failed` (failed retries on launch/foreground/pull-to-refresh). Read state: `unopened → opened → read` (never downgrades). `lastReaderMode` remembers scroll vs rsvp per article. Decoding defaults `readState` for pre-existing items.
- `Clip/ReadingList/ReadingListStore.swift` — JSON persistence in the App Group container (`group.com.hpiddy.clip`): `readingList.json` + `Articles/<uuid>.json` per article. Shared with the intent process. Posts `Notification.Name.readingListChanged` on every mutation. Reads disk fresh per call (simple over fast). Mutations are TARGETED (setLastWordIndex/markFailed/markReadState/setReaderMode/saveContent fetch fresh and set single fields) — whole-item writes from stale copies silently reverted other screens' fields.
- `Clip/ReadingList/ReadingListIngestor.swift` — fetch + extract orchestration; dedupes in-flight IDs; `ingestAllPending()` runs at launch/foreground. `handleSavePress(urlString:)` is the save entry point for intents and the in-app add: new URL saves+ingests, a repeat press within 12 s may send to Kindle (see `send-to-kindle.md`), any other repeat press is ignored. After successful `saveContent`, notifies `ArticleSendCoordinator.articleBecameReady`.
- `Clip/ReadingList/ArticleFetcher.swift` — `URLSession` GET, Googlebot UA first (soft-paywall bypass: crawler UA + no JS), Safari UA fallback.
- `Clip/ReadingList/ArticleExtractor.swift` — SwiftSoup mini-readability: strips `script/style/nav/header/footer/aside/form/iframe/svg/button`, scores parents by direct `<p>` text length, emits ordered blocks (`paragraph|heading|quote|listItem|image`) with UTF-16 inline link ranges, plus `author`. LAYERED, never fails while any text exists: refined (junk class/role stripping + trailing link-farm trimming; used only when ≥350 chars AND ≥1/3 of basic) → basic (structural-tag stripping only) → JSON-LD `articleBody` override (when it dwarfs the DOM result — React sites ship the article as metadata) → raw body text. Container scoring credits ancestors with decaying weight (readability-style) so per-paragraph div wrappers still resolve to the article container; the winner is then WIDENED upward until it covers ≥60% of the document's paragraph text (CMSs that split the body across sibling slice containers, e.g. itsnicethat).
- `Clip/ReadingList/ArticleContent.swift` — extracted content model (blocks + link ranges).
- `Clip/ReadingList/ReadingListViewController.swift` — home screen (insetGrouped). Rows show host · date · reading time (wordCount/220, toggleable) · progress % (toggleable). Section 0: unread (unopened bright `.label`, opened dimmed `.tertiaryLabel`, intermingled newest-first). Section 1: Read, dimmed, with a Delete All header button (confirmed via action sheet). `+` paste-a-URL alert, swipe left: Delete / RSVP (forces rsvp mode), tap → ReaderViewController, pull-to-refresh retries failures.
- `Clip/ReadingList/SafariURLStore.swift` — reads `lastSafariURL`/`lastSafariURLDate` App Group defaults written by the ClipSafari extension.
- `ClipShare/` — zero-UI share extension (`com.hpiddy.clip.share`, activation: 1 web URL). `ShareViewController` grabs the URL and `SharedReadingListAppender` appends a pending item directly to the App Group JSON (field names mirror `ReadingListItem` — keep in sync), then completes instantly; the app ingests on next launch.

## Tests

`ClipTests/ArticleExtractorTests.swift`, `ClipTests/ReadingListStoreTests.swift`.
