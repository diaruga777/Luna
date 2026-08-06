# Import & Export

Settings ▸ Import & Export is universal — one row in every app's settings tail
(`SettingsViewController`, next to Appearance), because every app can hand its
own links out and take a file back, and each keeps only its own kinds either
way.

## The file format

A two-column CSV, `section,url`, one row per link:

```
section,url
list,https://example.com/a
list,https://example.com/b
archive,https://example.com/old
```

`LinkListCSV` (LunaURLClassification, pure, `LinkListCSVTests`) owns both
directions. The shape was chosen over literal blocks separated by blank lines
for two reasons: it stays a *valid* CSV that a spreadsheet opens correctly, and
a reader that knows nothing about the format still sees one link per line — so
the fallback scrape recovers everything (minus the archive split) from the same
bytes.

Three things the reader has to get right, each of which was a real bug first:

- **The record walk goes over unicode scalars, not `Character`s.** Swift reads
  `\r\n` as ONE grapheme cluster, so a `Character`-based switch matches neither
  `"\r"` nor `"\n"` and a Windows-authored CSV collapses into a single enormous
  field.
- **BOMs are stripped over `unicodeScalars`.** U+FEFF is a default-ignorable
  code point, so Swift's canonically-equivalent comparison does not see a
  leading BOM as a `hasPrefix`; the marker stayed glued to the first header name
  and the file silently lost its structure.
- **The scrape bounds each match to a CSV FIELD.** A comma is legal in a URL
  path, so `NSDataDetector` run across a whole `title,url,time_added` row
  swallows the following columns and returns `https://example.com/1,1699999999`.
  Within a field an exact URL wins outright; anything else goes to the detector,
  which also knows real TLDs — that is why bare hosts are left to it rather than
  accepted directly, or a `3.14` score column would import as `https://3.14`.

**Reading a file is two paths.** A recognized header — a section column AND a
url column — takes the structured path and honors the archive. Anything else
falls back to scraping every link out of the raw text in reading order, all as
ordinary saves. A structured header above unparseable rows also falls back, so a
valid header never costs the user the links sitting below it.

Section-column aliases include `status` and `folder` on purpose: Pocket's
`status` and Instapaper's `Folder` already spell their archive `archive`, and the
`arch`-prefix rule imports those exports WITH their archive split rather than
flattening them.

## Export

`LinkListExport.document(for:)` takes the store's items, newest first, and
splits them by `isArchived`.

- **Scoped by `LunaApp.includes`.** The store is shared by all four apps, and a
  Reader export carrying the Downloader's videos would hand back a file whose
  own re-import Reader then rejects.
- Synthetic URLs (`lunadoc://`, `lunamail://`) are left out — they name bytes
  inside one device's container.
- The file is written to the temporary directory as
  `Luna-Links-<yyyy-MM-dd>.csv` (per-app prefix) and handed to the system share
  sheet.

## Import

1. `UIDocumentPickerViewController(forOpeningContentTypes:asCopy: true)` — a copy,
   so the file is readable without coordinating against an original in another
   app's container. CSV, plain text, and their common `.text` supertype.
2. Bytes → text: UTF-8, then UTF-16 (what a spreadsheet's "Unicode text" writes),
   then Latin-1, which cannot fail — so one bad byte never costs the user a
   file's worth of links.
3. `LinkImportSheetViewController` (app shell, `Luna/Settings/`) — the review
   sheet.

### The sheet

One controller across three stages — review, progress, summary — because they
are one continuous act: the table stays put and its content is replaced, so the
sheet never blinks out from under the user mid-import. A large detent, and it
**refuses a swipe-away while links are being saved**, since the run would
otherwise carry on with nothing on screen showing it.

Review lists the found links in two sections (Links / Archive; an empty one is
not rendered), each row a path over its host, all selected by default. The
selection control is a LEADING circle that fills when chosen, so it sits where
the eye and thumb already are; a trailing checkmark would read as "just tapped"
rather than "included". Import and Cancel sit at the bottom.

The list stays up during the import, frozen and non-interactive — its filled
circles are the record of what was chosen, and hiding it would leave the sheet's
middle blank with the bar stranded at the bottom.

### The run

`LinkImportRunner` (LunaReadingList, `LinkImportRunnerTests`). Kind-neutral: the
media leg is an injected seam, so the module keeps linking no kind package.

**Placement is one write.** `ReadingListStore.insertImported` puts the whole
batch in a single coordinated `readingList.json` mutation, and has to **stagger
`dateAdded` backward** across it: every deck sorts by `bumpDate ?? dateAdded`
descending, not by array position, so N links stamped with the same `Date()`
come out ordered by UUID — the file's order lost. Archived candidates arrive
already archived, in that same write, so an interrupted batch cannot leave
archived saves sitting in the deck.

It also pins `lastSaveAttemptDate` to `.distantPast`. The save-press window falls
back to `dateAdded` when that field is nil, and a just-imported URL shared from
Safari seconds later would read as the SECOND press on that item and route to
Kindle. **An import is not a save press** — which is also why it goes through
`store.insertImported` + `ingest` rather than `handleSavePress`, so none of the
new-save automation (auto-share to always-friends, semantic suggestions) fires
several hundred times.

**Two phases.** Phase one ingests `defaultConcurrency()` links at a time through
the ordinary `ReadingListIngestor.ingest`, so an imported link is classified,
gated, fetched and stored exactly like any other save. Phase two retries the
failures with Apple Intelligence, ONE at a time — a model call is the one
resource on the device that gains nothing from being asked twice at once, which
is why `URLRescueCoordinator`'s own background sweep serializes too. Splitting
them also keeps the arithmetic honest: a link that never failed is simply
finished at the end of phase one.

`allowsInteractivePrompt: false` is load-bearing twice over. It suppresses the
unsupported-kind modal — `.manual` is an interactive source, so a batch of
foreign links would otherwise stack one alert per dropped link on top of the
progress sheet — and it makes the ingestor's own `rescueTrigger`
non-interactive, so a failure is left alone instead of starting an inline rescue
that would race phase two's awaited one over the same item.
`URLRescueCoordinator.rescueAndWait` is the awaited form of the consented
one-shot rescue; the import can't use the fire-and-forget one because it has to
know each item's fate to score the run.

**Permissions are asked for at the top, not mid-run.**
`LinkImportRunner.mediaStoragePreflight` (installed by the media `KindWiring`s
over `MediaPhotosPreflight`) runs before the first write. The media path's own
prompts land at the worst possible moment during a batch: a non-Downloader save
asks for add-only access in the transfer's start gate, and a Downloader save
skips that and asks for read/write when the FIRST transfer *finishes* — a system
alert over a moving progress bar, with a queue behind it that fails as
`.photosPermission` while the user reads it. The preflight asks for **read/write**
(the superset both paths end up needing, and granting it also answers the
add-only status, so one prompt replaces two) and only when it could matter:
storage is set to Photos AND at least one candidate URL is downloadable by the
PURE test — the platform table or a direct-media path extension — so an
articles-only file imported through the central app never sees a Photos prompt.
A refusal doesn't stop the import; the media leg reports its own permission
failures as before.

**The run is silent.** `LinkImportRunner.mediaAlertSuspension` (installed by the
media `KindWiring`s over `LiveMediaDownloadManager.suspend/resumeActivityAlerts`,
counted so overlapping runs can't un-suspend each other) drops the download Live
Activity's start and finish `AlertConfiguration`s — banner, sound and **haptic** —
for the length of the run, restored in a `defer` so a stopped run restores them
too. The activities themselves still appear and still update; only the alerts go.
A file of two hundred social links otherwise buzzed the device four hundred times
while the sheet's own progress bar was already reporting each one. The suspension
is process-wide rather than a `@TaskLocal` like `systemProvidesProgressUI`,
because the finish alert fires from the background `URLSession`'s delegate
callback — a task tree with no relation to whoever started the transfer, so a
task-scoped binding would silence every start and let every finish through.

**Concurrency** is `min(6, max(2, activeProcessorCount / 2))`, halved again in
Low Power Mode. The floor of 2 exists because most of an ingest is network wait;
the ceiling because past it `URLSession`'s per-host limit and the extractor's
memory cost make more workers pure contention.

### Progress

The bar is `MoonHorizonProgressBar` — the shared horizon arc every other
progress surface in the four apps uses (media cards, the mini player, the clip
download screen, the Live Activity's SwiftUI twin). There is no import-specific
bar: the flat `EclipseProgressBar` this sheet used to carry is deleted, and its
two other call sites (the failed-save card's rescue bar, the carousel host's
media loading shell) moved to the arc with it.

Each link owns an equal `1/N` slice. Within a slice: the ingest owns up to 0.55,
a media download or a rescue carries it to 0.95, and the last sliver lands when
the item is scored — so a finished slice always looks finished. A slice never
moves backward.

Progress is **pulled**, not pushed: the sheet reads `currentProgress()` on a
1/12 s timer. Pushing would mean thousands of notifications a second from several
concurrent transfers, and the two legs that advance on a clock (a page fetch, a
model call) have nothing to push anyway. An open ingest therefore gets a
clock-based estimate that eases toward the end of its share — a fetch reports
nothing until it lands, and a frozen bar reads as a hung import. Easing, never
linear: an overrunning fetch slows down instead of stalling at a wall.

A rescue's fraction comes from the rescue's own reported stage
(`URLRescueCoordinator.rescueProgress`), and a media download's from
`MediaImportProgress` — which reads the transfer's **phase**, not its fraction: a
failed transfer stops short and a saving one sits at 1 for a moment, so a
fraction alone would either strand the slice open until its deadline or close it
before the file was durable. That file is media-only and takes a membership
exception in the Reader and Price Tracker sets; in those apps the seam stays nil,
which is correct — a media link can't pass their content gate, so no transfer
ever exists to watch.

The first look for a transfer is decisive, with no grace period: the media ingest
handler awaits `LiveMediaDownloadManager.start` before returning, so by the time
the runner looks the job either exists or was never going to. A grace period
would cost every non-downloadable social save a pointless pause, which over a few
hundred of them is minutes. If that handler ever becomes fire-and-forget the only
consequence is a coarser bar, not a wrong result. A transfer still running after
`downloadWait` (180 s) is left to finish in the background, where it has its own
Live Activity.

### The summary

Four buckets, all of which must account for every candidate exactly once:

- **imported** — content ready, or `.needsCaptcha`, which is a titled save the
  user unlocks by tapping it: a working item, not a failure to retry.
- **couldn't be downloaded yet** — saved, but the content didn't come down even
  after the model retry. Real saves that Luna keeps retrying on its own, hence
  recoverable, and deliberately NOT listed as rejected.
- **already saved** — the URL was in the list before; nothing was written.
- **not saved** — listed with their URLs and why: a kind this app doesn't handle
  (naming the sibling app that does, where it's known), or nothing usable could
  be made of the URL.

Stopping mid-run is safe by construction: every link was already placed by phase
zero, so anything unreached is saved and pending and Luna's ordinary launch sweep
finishes it. Those count as recoverable, and the summary says so.

## Tests

`LunaTests/LinkListCSVTests.swift` (codec), `LinkListExportTests.swift` (what
leaves and what is accepted back), `LinkImportRunnerTests.swift` (orchestration,
with both real operations stubbed).
