# Import & Export

Settings ▸ Import & Export is universal — one row in every app's settings tail
(`SettingsViewController`, next to Appearance), because every app can hand its
own links out and take a file back, and each keeps only its own kinds either
way.

## The file format

**Markdown**, one bullet per link, under a `## Links` and a `## Archive`
heading:

```markdown
# Luna Reader Links

Exported 2026-08-06. Keep the two headings below and Luna reads the archive
back as an archive when this file is imported again.

## Links (2)

- [Some Piece](https://example.com/a)
- https://example.com/b

## Archive (1)

- [An Old One](https://example.com/old)
```

`LinkListMarkdown` (LunaURLClassification, pure, `LinkListMarkdownTests`) owns
both directions.

**It replaced a `section,url` CSV, which was correct and unreadable.**
AirDropping the `.csv` routed it into Notes, and what came back out of Notes was
text with no CSV left in it — so the whole file re-imported as one flat list and
the archive split was gone. Markdown survives that trip because its structure is
*prose*: a heading is still a heading after a rich-text editor has dropped the
`##`, and a bullet is still a line with a link on it. It is also legible on
arrival, which the CSV never was.

**Titles travel.** Each bullet is `[Title](url)` when the save has a title, so a
re-import shows real headlines in the review list without fetching anything
(`LinkListDocument.titles`, keyed by URL). A bare-URL line is still a link, so a
hand-written list imports fine.

**The headings are not localized**, for the same reason the export filename
isn't: the file travels between devices, apps and people, and the headings are
the machine-readable half of the format.

### Reading it back

`LinkListFile.parse` is the one entry point, three tiers, each falling through
so a file never costs the user the links sitting in it:

1. **`LinkListMarkdown`** — Luna's own format, and anything else whose text
   carries a recognizable heading. The reader does NOT require the `##`, the
   `-`, or the exact word: a **short line with no address in it** whose letters
   start with `arch` opens the archive, and one reading `links` / `unread` /
   `saved` / `inbox` / `saves list` opens the live list, so `**Archive**`,
   `ARCHIVE:`, `## Archive (128)` and a bare `Archive` all work. A line
   containing anything but letters, digits, spaces and decoration is not a
   heading — that one rule is what stops `archive.example.com` and
   `[Archive](https://…)` from re-sectioning the file. Links found above the
   first heading are ordinary saves.
2. **`LinkListCSV`** — a header naming a section column and a url column, which
   is what Pocket's `status` and Instapaper's `Folder` exports are; their
   archive split is honored. Section-column aliases include `status` and
   `folder` on purpose, and the `arch`-prefix rule imports those files WITH
   their split rather than flattening them. There is no CSV *encoder* any more.
3. **A scrape** — every http(s) link in the text, in reading order, all as
   ordinary saves: a one-URL-per-line list, a foreign CSV with no section
   column, a pasted email.

Three things the CSV/scrape tier has to get right, each of which was a real bug
first:

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

A tier that yields nothing falls through to the next, so a valid header above
unparseable rows — or headings with nothing under them — never costs the user the
links sitting elsewhere in the file.

## Export

`LinkListExport.document(for:)` takes the store's items, newest first, and
splits them by `isArchived`.

- **Scoped by `LunaApp.includes`.** The store is shared by all four apps, and a
  Reader export carrying the Downloader's videos would hand back a file whose
  own re-import Reader then rejects.
- Synthetic URLs (`lunadoc://`, `lunamail://`) are left out — they name bytes
  inside one device's container.
- Each item's title comes along, so the file reads as a list of pieces rather
  than a list of URLs.
- The file is written to the temporary directory as
  `Luna-Links-<yyyy-MM-dd>.md` (per-app prefix) and handed to the system share
  sheet.

## Import

1. `UIDocumentPickerViewController(forOpeningContentTypes:asCopy: true)` — a copy,
   so the file is readable without coordinating against an original in another
   app's container. Markdown (named explicitly, not just inherited through
   `.text` — a file tagged `net.daringfireball.markdown` is otherwise offered
   greyed out on some hosts), CSV, plain text, and their common `.text`
   supertype.
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
not rendered), all selected by default. The selection control is a LEADING circle
that fills when chosen, so it sits where the eye and thumb already are; a
trailing checkmark would read as "just tapped" rather than "included". Import and
Cancel sit at the bottom.

### The rows, and their previews

A row's headline is the best answer available, in this order: what the PAGE calls
itself, then the title the FILE carried (a Luna markdown export writes one), then
the URL's path — which always exists, so a row is never blank and a preview is
only ever an upgrade. Its second line is the publisher when the page names one,
else the host, so two pieces with the same headline stay tellable apart.

`LinkImportPreviewLoader` (app shell) fetches those previews in a **rolling
window** around what is on screen. A file can hold a thousand links and each
preview is a real page read, so fetching the file would be minutes of cellular
data for rows the user scrolls straight past. The window is exactly the table's
own `willDisplay` plus its `UITableViewDataSourcePrefetching` lead; a row that
leaves before its turn comes up is dropped from the queue unfetched, which is the
whole point, while one already in flight is left to finish (the bytes are spent
either way, and scrolling back is likely). Three reads at a time — enough to keep
a scrolling window filled, few enough not to starve the import itself, which
shares the connection and matters more.

- One request per row: `LinkPreviewFetcher` (LunaFetch) reads the page once and
  runs both pure parses over the same HTML — `PageMetadataFetcher`'s title/site
  and `LeadImageExtractor`'s `og:image`. Its homepage fallback is deliberately
  NOT used here: that exists to *name* a failed save, and a review row headed by
  the publisher's homepage title would be a wrong answer dressed as a right one.
- **Text lands before the picture.** The headline is the useful half and doesn't
  wait on an image download that may not arrive.
- Thumbnails are decoded to the 56×40pt box off the main actor
  (`ImageDownsampling.decode(data:…)`) and held in an `NSCache`, so a
  fully-scrolled thousand-link file can't hold a thousand bitmaps. Losing one to
  eviction costs the row its picture, not another fetch.
- **Offline fails fast, with no spinner at all**: `NetworkReachability.isOnline`
  is checked before a row is queued, so a row on a plane reads as "this is all
  there is" rather than "still loading". Same for a page that doesn't answer, and
  for a URL that isn't fetchable — which is tested by scheme and host, because
  modern Foundation parses `"not a url"` into a schemeless `URL` that only fails
  later, at request time.
- A row is asked once. A page with nothing usable is *answered* with an empty
  preview rather than retried every time it scrolls back into view.

The list stays up during the import, frozen and non-interactive — its filled
circles are the record of what was chosen, and hiding it would leave the sheet's
middle blank with the bar stranded at the bottom.

### The run

`LinkImportRunner` (LunaSaves, `LinkImportRunnerTests`). Kind-neutral: the
media leg is an injected seam, so the module keeps linking no kind package.

**Placement is one write.** `SavesStore.insertImported` puts the whole
batch in ONE transaction, and has to **stagger
`dateAdded` backward** across it: every deck sorts by `bumpDate ?? dateAdded`
descending, not by row order, so N links stamped with the same `Date()`
come out ordered by UUID — the batch's own order lost. Archived candidates arrive
already archived, in that same write, so an interrupted batch cannot leave
archived saves sitting in the deck.

It also pins `lastSaveAttemptDate` to `.distantPast`. The save-press window falls
back to `dateAdded` when that field is nil, and a just-imported URL shared from
Safari seconds later would read as the SECOND press on that item and route to
Kindle. **An import is not a save press** — which is also why it goes through
`store.insertImported` + `ingest` rather than `handleSavePress`, so none of the
new-save automation (auto-share to always-friends, semantic suggestions) fires
several hundred times.

**The web-unlock pass.** Between the ingest and the model retry, every save that
came back `.needsCaptcha` — hard-paywalled, which the silent tier can't read by
construction — gets ONE attempt through the real browser flow a tap would run:
`LinkImportRunner.articleUnlocker` → `UnattendedArticleUnlock` (LunaArchiveReader,
installed by the article `KindWiring`s; nil in the Downloader and Price Tracker,
where no article save exists). Doing it here, while the user is already waiting,
beats leaving two hundred locked saves to be tapped one at a time.

- **It gives up on a CAPTCHA, immediately.** `ArchiveWebReaderViewController`
  gains a `.unattended` mode: where the interactive flow uncovers the page for the
  user to solve a challenge, or shows a rate-limit message with a Safari escape,
  the unattended one reports `onGaveUp` and stops. Nothing is written, so the save
  stays exactly as it was — titled, tappable, `.needsCaptcha` — for the user to
  open when they choose. There is no failure here to report, which is why the
  summary has no bucket for it: a locked save counts as **imported** whether or
  not the unlock worked, exactly as it did before this pass existed.
- **The web view is out of sight, not hidden.** It is installed full-size at the
  BOTTOM of the key window, behind the app's own opaque UI, and
  non-interactive. That distinction is load-bearing: WebKit throttles and
  eventually stops JS and navigation in a view that is hidden, zero-sized or out
  of a window, and this flow is entirely JS-driven (a DOM probe every 0.35s, a
  form submit, a DOM extraction). Occluded is fine. It also means the progress
  sheet is never interrupted — no modal, no reveal, nothing to dismiss.
- **Serial, with an idle deadline.** One `WKWebView` at a time, both because each is
  expensive and because two racing archive.today is the quickest way to be
  rate-limited. WebKit's resource progress resets a 30s per-link idle watchdog
  (`UnattendedArticleUnlock.defaultTimeout`), so a slow page may take longer while
  data keeps arriving; thirty silent seconds abandons the attempt rather than
  failing the save. The watchdog uses an unstructured timeout race: a structured
  task group would choose its deadline result and then wait forever while draining
  a WebKit continuation that ignores cancellation. Stopping the run skips the
  remaining unlocks and costs nothing.
- Its slice takes the same `ingestShare`→`followUpShare` stretch a download or a
  rescue would, eased on the clock (`expectedUnlockDuration`) because the flow
  reports nothing while it runs.

**Three passes, in order.** The ingest runs `defaultConcurrency()` links at a
time through the ordinary `SavesIngestor.ingest`, so an imported link is
classified, gated, fetched and stored exactly like any other save. Then the
web-unlock pass above, serially. Then the failures are retried with Apple
Intelligence, ONE at a time — a model call is the one resource on the device that
gains nothing from being asked twice at once, which is why
`URLRescueCoordinator`'s own background sweep serializes too. Splitting them also
keeps the arithmetic honest: a link that neither locked nor failed is simply
finished at the end of the ingest.

`allowsInteractivePrompt: false` is load-bearing twice over. It suppresses the
unsupported-kind modal — `.manual` is an interactive source, so a batch of
foreign links would otherwise stack one alert per dropped link on top of the
progress sheet — and it makes the ingestor's own `rescueTrigger`
non-interactive, so a failure is left alone instead of starting an inline rescue
that would race the model pass's awaited one over the same item.
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

**No link can hold the batch open.** Each ingest has a 30s idle watchdog. Pipeline
diagnostic progress and received-byte growth reset it, so a large response may run
longer while it streams consistently; a silent or cancellation-uncooperative task
is cancelled and abandoned without draining it. Because every placeholder was
inserted before the workers started, that link remains durable for Luna's launch
sweep and the worker slot immediately advances to the next link. Media transfers
use the same 30s silence rule while also retaining their 180s foreground-wait cap;
anything beyond that continues through the background URLSession.

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

`LunaTests/LinkListMarkdownTests.swift` (Luna's own format + the tier order),
`LinkListCSVTests.swift` (the foreign-CSV and scrape tiers),
`LinkListExportTests.swift` (what
leaves and what is accepted back), `LinkImportRunnerTests.swift` (orchestration,
with both real operations stubbed), `LinkImportPreviewLoaderTests.swift` (the
rolling window and the row copy).
