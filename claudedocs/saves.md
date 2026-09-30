# Saves & Ingestion

Luna is a weblink reader: links saved from Safari (extension + intent) or pasted
in-app are downloaded, stripped to readable text, and read in two reader modes.
Every save from every surface lands in ONE store, `saves.sqlite` in the shared App
Group container, and each app shows the kinds it owns.

## The store

`LunaStorage/SavesStore.swift` is the public API — `items()`, `add`, the targeted
setters, `saveContent`, `delete` — over `SavesDatabase`, a SQLite connection on
the system `libsqlite3`. There is no package dependency: the Safari appexes link
LunaStorage too and have a memory ceiling to keep.

**One connection per process, behind one serial queue** (`SavesDatabase`). Each
Luna process — the four apps, their share / action / Safari extensions, the App
Intents, the mail-fetch background task — opens its own connection to the same
file. The configuration is the standard cross-process arrangement:

- `journal_mode = WAL`, so readers do not block the one writer. The `-wal` /
  `-shm` siblings live beside the database, which is why other processes need
  access to the App Group DIRECTORY rather than just the file.
- `busy_timeout = 5000`, so a second writer waits its turn instead of failing.
  Switching journal mode takes a lock the timeout does not cover, so that one
  pragma is retried by hand (`retryingWhileBusy`) — every process racing to open a
  brand-new file attempts the switch at once.
- `synchronous = NORMAL`, `foreign_keys = ON` (per connection, so every process
  re-applies it).
- File protection `completeUntilFirstUserAuthentication`, applied through the
  open flag so it covers the `-wal` / `-shm` siblings: the extensions and the
  mail-fetch task write while the device is locked.

A mutation is one `BEGIN IMMEDIATE` transaction, so two processes that
read-modify-write at the same moment take turns rather than losing one side's
update. `items()` serves an in-memory list validated against `PRAGMA
data_version` — which changes only when ANOTHER connection commits — so a
repeated read costs one pragma and a sibling's write is picked up on the next
call without waiting for a notification. Every mutation also posts
`Notification.Name.savesChanged` (wire name `"readingListChanged"`), which is
what makes each deck reload.

Prepared statements are cached by SQL on the connection, so the hot paths — a
point read, a resume-position write — re-prepare nothing. Resume positions go
through `asyncUpdate` on a serial queue off the main thread; `flushPendingUpdates`
is the test seam that waits for them.

## The schema

Schema 15 also adds Luna Keyboard preferences, shortcuts, keyword mappings and its
personal dictionary. Shortcut media uses the same ownership edges and reaper;
see [keyboard.md](keyboard.md).

`LunaStorage/SavesSchema.swift` holds every table, index and trigger, created
idempotently at open and stamped into `PRAGMA user_version`. **Every field is a
typed column — there is no payload blob**, so a reader never has to understand a
writer's version of a struct to read a column it does know.

Schema 11 also repairs an ambiguous schema-6 rollout: two shipped builds used the
same version stamp for different `preload_pages` layouts. Open therefore inspects
that table's columns rather than trusting `user_version`; only the obsolete
two-column layout is released and rebuilt, while a complete layout (including one
with additive columns from a newer sibling) is preserved. Rebuilding releases its
ownership edges and queues/tombstones the old page files before dropping the map.

The SQL transition has no in-place compatibility promise: pre-SQL and intermediate
development installs are wiped manually, and mixed-version app/extension operation is
unsupported. Consequently startup never imports, resets, or deletes retired JSON stores
(`savedMedia.json`, `jobs.json`, or `Library/ProductSnapshots`). Leaving an unidentified
old artifact inert is safer than letting migration cleanup race with and erase fresh SQL
rows or directories.

- `saves` — one row per save (`WITHOUT ROWID`, TEXT id). `seq` is the list's own
  order, highest first: a new save goes to the front and `bump` moves one there,
  independently of the dates a deck sorts by. URL, title, the dates, the state
  and read-state enums, reader positions, document type, platform +
  `platform_item_id`, capture source, and the three artifact file-name columns.
- `send_states` — the five per-destination send dictionaries normalised, PK
  `(save_id, destination)`. Each column is independently absent, which is what
  the dictionaries express: a delivered send clears its retry columns and keeps
  its date.
- `price_trackers` (PK `save_id`), `tracker_rejected_sellers`, `tracker_stores`,
  `tracker_price_points` — the tracker payload of a save that is one. Absent for
  every other save, which is what makes the save an article or a video instead.
  A price point's PK is `(store_id, day)`: a second observation on the same day
  lowers the row rather than adding one.
- `product_snapshots` and `product_snapshot_keys` — passive product-page
  observations and their indexed identifier/name buckets. They are independent
  of saves: a page visit records an observation without creating a save. The
  key table cascades when an observation is pruned; no snapshot JSON is stored.
- `spotlight_surface_index` and `spotlight_surface_state` — the save ids each
  article app last handed to its own bundle-specific Core Spotlight index, plus
  its one-time legacy-reconciliation marker. The old shared `spotlight_index`
  table remains for mixed-version binaries; schema 10 offers its ids, and the
  still older App-Group defaults ids, to Luna and Reader independently once.
- `media_download_jobs` — durable in-flight download state. Its
  `background_session_identifier` assigns the job to the exact app or embedded
  extension process that created its background URLSession task, so another
  process sharing the database cannot mistake that task for missing and restart
  it in a different session.
- Every save-owned child table is `REFERENCES saves(id) ON DELETE CASCADE`, so
  deleting a save is the row delete. Passive snapshot rows are intentionally
  independent of saves, while their key rows cascade from the snapshot.
- **Schema 12 and 13 add the plugin platform's own tables and columns**
  (central Luna only writes them; the three sibling apps never read them but
  must not fail on them, per the no-CHECK-constraint rule below).
  `saves.plugin_id`, `tracker_stores.plugin_id` and
  `media_download_jobs.plugin_id` name the owning plugin, NULL for a
  Swift-ingested save; `media_download_jobs` also gained
  `request_headers_json`, `expires_at` (schema 12) and `quality` (schema 13,
  for matching a re-resolved asset back to its job). `plugin_kv` and
  `plugin_collections` are `luna.storage`'s key/value and document tables,
  scoped by `plugin_id`; `plugin_browser_requests` holds one row per save
  waiting on a plugin's browser step (§8 of `claudedocs/plugins.md`); and
  `pending_plugin_models` is the Safari → app hand-off queue for a Model the
  content script already produced. Full detail: `claudedocs/plugins.md`.

Three deliberate choices:

- **No CHECK constraint on the enum columns.** Four apps and their extensions
  share one file and update independently, so a newer sibling WILL write a case
  an older binary has never heard of. A constraint would turn that into a failed
  insert for the newer app or a failed read for the older one. Raw TEXT plus a
  tolerant mapping in Swift (`SaveRow`, unknown → safe default) keeps both
  running. Closing a value set is a `user_version` bump and a migration.
- **Dates are REAL** (seconds since the reference date), so a value round-trips
  to the same `Date` it was written from — items compare by value and the decks
  sort on these.
- **Prices are TEXT**, so a `Decimal` keeps its exact digits.

Indexes exist per query that exists and no others: `saves(seq DESC)` for
`items()`, `saves(url_string)` for the URL dedup every surface runs, a partial
index on `pending_archive_at`, `tracker_stores(url_string)` for the
already-tracked-seller check, and the FK covering indexes SQLite does not create
itself (`tracker_stores(save_id)`, `product_snapshot_keys(snapshot_id)`,
`file_refs(save_id)`, `file_holders(holder_key)`).

## File ownership, in SQL

The payload FILES — parsed article JSON, captured web archives, imported
documents, thumbnails, product photos, downloaded article images — stay on disk
beside the database (`Articles/`, `OriginalArchives/`). WHO OWNS THEM is in the
database, written in the same transaction as the row that made them. See
`LunaStorage/SavedFileOwnership.swift` for the writes.

- `files(id, relative_path UNIQUE, kind)` — one row per owned artifact. The path
  is its identity. A live image may be shared by several saves, while a new
  download always gets a fresh URL-independent filename. `OwnedFileKind` says
  what it is (`content`, `archive`, `readerSource`,
  `document`, `thumbnail`, `productImage`, `image`, `preloadPage`), which is what
  lets a save reconcile one sort of artifact without disturbing the others.
- `file_refs(file_id, save_id)` — which saves hold which files. **The reference
  count is the edge count**, so there is no counter to drift, and a save's delete
  cascades here: a delete cannot forget an artifact.
- `file_holders(file_id, holder_key)` — the same ownership for a holder that is
  NOT a save. Two kinds of holder use it. A preloaded page (`PreloadStore`, keyed
  by the page's URL hash) downloads its images into the same shared `Articles/`
  cache a save reads from, so one table has to count both or a save's delete
  would take a live page's picture with it. The two preload owners that are not
  saves — the tapped link and the pasteboard candidate — hold their PAGES here
  under a `preload-owner:<uuid>` key, because there is no save row for them to
  cascade from. No foreign key: the holder lives outside this database.
- `preload_pages(url_key, file_id, url_string, kind, last_loaded_at, has_content)`
  — one preloaded page: the file it owns plus everything the crawl learned about
  it. See **Preloaded pages** below.
- `preload_page_links(url_key, position, child_url_key)` — the outbound links one
  page reached, in document order, so a second save landing on a cached page can
  claim the subtree below it.
- `media_saves(save_id, source_url_string, title, date_saved, archived_at, kind,
  storage_state, file_name, photos_identifier, thumbnail_file_name, platform,
  platform_item_id)` — the downloaded-media payload of a save that is one, the
  twin of `price_trackers`. See **Downloaded media** below.
- `pending_deletes(relative_path, enqueued_at, attempts)` — files whose last
  holder is gone, waiting to be unlinked.
- `retired_paths(relative_path, retired_at)` — permanent tombstones. A path is
  inserted here in the same trigger that enqueues deletion and is never reused,
  even after the queue row has been cleared.
- `image_sources(source_url, file_id)` — the current live local copy of an image
  URL. It is removed with its `files` row, so it never identifies a retired path.

The invariant no Swift caller is trusted with — **a `files` row never sits at zero
holders** — is enforced by triggers, because all four apps and their extensions
write these tables. An `AFTER DELETE` on either edge table checks for remaining
edges of both kinds and, when none are left, queues the path in `pending_deletes`
and drops the `files` row. A queued path is recorded in `retired_paths` as a
permanent tombstone: no edge insert can claim it, even after reaping, and the
reaper removes it even if a legacy inconsistent database still has a `files` row.
A downloader can reuse an image only by atomically claiming its live
`image_sources` mapping under SQLite's write lock; otherwise it downloads to a
fresh UUID filename. The release trigger fires for a cascade-driven delete too,
pinned by `SavedFileOwnershipTests`.

**Preloaded pages live here too.** The preload cache keeps each page's BODY as a
file in its own `Preloads/` directory (`claudedocs/preload-plan.md`), but nothing
else: there is no `preloads.json` any more, and there never was an owner set in
SQL's place. `preload_pages` carries the page's kind, load date and content flag,
`preload_page_links` its outbound links, and:
`preload_pages(url_key, file_id)` points at the page's file and the page's owners
are ordinary edges on that `files` row. So a save's delete cascades to its whole
preload subtree, the release trigger queues each emptied page's file, and the one
reaper unlinks it. Three consequences:

- A page's file name is `page-<UUID>.json`, not the URL hash it used to be. The
  mapping is a table for the same reason `image_sources` is one: the path is
  retired on release, so a page reloaded later must land somewhere new.
- A page that caches no content — a platform link, an unrepresentable one — still
  gets a row, reserving a NAME it never writes. That is what lets one mechanism
  count every page; the reaper already treats a queued path whose file is absent
  as done.
- An article body is installed with an atomic file replacement before
  `has_content` and `last_loaded_at` are advanced. A failed first write remains
  content-less and immediately retryable; a failed re-record or viewer refresh
  retains the older readable body, timestamp, image holdings, and memory-cache
  value as one consistent version.
- A page's IMAGES are held under the page's own key, which cascades from nothing,
  so a `preload_pages_release` trigger drops those holds when the row goes and the
  holder trigger frees any image no save still wants. `releaseTree` is left with
  only what SQL cannot do: evicting this process's decoded copies.

**Downloaded media.** `media_saves` is the same shape one level up: the media file
and its poster are `files` rows of kind `mediaFile` / `mediaThumbnail`, owned by
`file_refs`, and the row itself cascades with the save. `SavedMediaStore` unlinks
nothing — every mutation ends in one `SavesStore.reconcileMediaFiles` call that
makes the save's media holdings exactly what the row still names. That is also
what retired the two-write Photos transition: the row stops naming the file, the
trigger queues it, and the reaper unlinks it whenever the process next runs, so
there are no `pendingLocal*` names to recover from. A download claims its file
BEFORE the row commits (`claimMediaFiles`), so a process killed in between leaves
a file the database owns rather than one nobody does. Posters are generated names
(`thumb-<UUID>.jpg`), not derived from the item id, for the tombstone reason
above. And a download needs its save row first — `MediaSaveBacking` reserves one
when the URL has none — because a row with no save owns nothing.

**The reaper is the second commit.** A file system cannot join a transaction, so
releasing an artifact is two commits: the transaction records the intent, and
`PendingDeleteReaper` unlinks the file and clears the row afterwards. Any process
may run it, at any time, as often as it likes — it runs after the mutations that
queue something, at launch, and when an app backgrounds
(`SavesStore.reapPendingDeletes`). Each path is handled in its own transaction,
so two processes reaping at once is harmless: the second finds the row gone. The
unlink happens INSIDE that transaction on purpose, holding the write lock across
it, so every attempted claim serializes with the tombstone and delete. A crash
between commit and unlink leaves the row, so the work is
retried; `attempts` earns a log line after five failures and keeps the row.
`enqueued_at` is UNIX seconds rather than reference-date seconds because a
TRIGGER writes it and SQLite's own clock is the only one a trigger can read —
nothing queries it, so it is a diagnostic and gets no index.

## Surface presentation — decks, not a list

Every app's home screen is a card deck, built by its own
`KindWiring.makeRootViewController()`: `ArticleCardsViewController` for central
Luna and Reader, `MediaCardDeck.makeRoot()` for the Downloader,
`ProductCardDeck.makeRoot()` for the Price Tracker — all of them the one
`CardCarouselHostViewController` plus that kind's `CardDeckProviding` half (see
`card-carousel.md`). Every deck permanently begins
with the util card and has a right-edge archive tray. When there are no saves the
util card is centered; otherwise the leftmost save is centered and the util card
is one swipe to the left. See `util-card.md`.

Which items an app shows is `LunaApp.includes` (in `LunaSavesUI`, alongside the
`SavesSectioning` predicates it needs); what an app ACCEPTS is `SurfaceSupport`,
the ingest gate. Both key off `LunaApp.current`.

There was once a sectioned table list. It and everything that served only it (the
row cell, the row-menu factory, the group builder, the `ListKindSupport`
registry, the list's pasteboard controller, the diff, the subtitle formatter) were
deleted when every app rooted on a card deck. Older passages in
`card-carousel.md` / `price-tracking.md` / `safari-extension.md` still narrate
list rows; read those as history, and read "row" as the equivalent card
affordance.

## Key files

- `LunaModels/SavedItem.swift` — the model. Content state: `pending → ready |
  failed | needsCaptcha` (failed retries on launch/foreground/pull-to-refresh;
  `needsCaptcha` is a hard-paywall holding state — see **Hard paywalls** below —
  that only the user can advance, so it is NOT retried by `ingestAllPending`).
  Read state: `unopened → opened → read` (never downgrades). `archivedAt` moves
  Reader items out of the carousel into its right-edge archive tray without
  removing content. Archiving calls `PreloadStore.releaseTree(rootID:)`, so the
  save keeps its complete article/original artifacts but owns no recursive
  preloads (effective depth 0); unarchiving does not automatically rebuild the
  tree. `lastReaderMode` remembers scroll vs rsvp per article. Scroll/word
  position writes remain asynchronous during ordinary reader teardown, but the
  RabbitHole host drains them synchronously on `didEnterBackground` so a
  force-quit cannot lose the latest position before a cold launch.
- The Reader carousel keeps completed articles as ordinary live-reader cards for
  now, sorted after every unopened/in-progress card (newest/bumped-first within
  each group). Completed cards start at the article opening instead of restoring
  their terminal footer offset; unfinished cards restore their exact saved
  scroll position.
- `LunaStorage/SavesStore.swift` — the store described above. Mutations are
  TARGETED (`setLastWordIndex` / `markFailed` / `markReadState` / `setReaderMode`
  / `saveContent` each read fresh and set single fields) — whole-item writes from
  stale copies silently reverted other screens' fields. Content files are read
  and written through `content(for:)` / `saveContent`, which also claims the
  ownership edges for whatever the write made.
- `LunaSaves/SavesIngestor.swift` — fetch + extract orchestration; dedupes
  in-flight IDs; `ingestAllPending()` runs at launch/foreground.
  `handleSavePress(urlString:)` is the save entry point for intents and the
  in-app add: a new URL saves+ingests, a repeat press within 12 s may send to
  Kindle (see `send-to-kindle.md`), any other repeat press is ignored. After a
  successful `saveContent` it reports readiness through `SaveReadiness.observer`.
  New-save automation (auto-share to always-friends `fireAutoShares` +
  `armSemanticSuggestionIfNeeded`) is factored out and shared with
  `saveNewWithContent(urlString:content:)` — the latter persists already-fetched
  content directly.
- **News-aggregator unwrapping** (`LunaURLClassification/NewsAggregatorUnwrapper.swift`):
  the FIRST thing `ingest` does is unwrap a wrapper URL to the real publisher
  article — a wrapper breaks BOTH extraction (the aggregator page is a JS shell)
  and the archive flow (archive.today can't snapshot it). `unwrap(_:)` (async;
  returns nil after a cheap host check for non-wrappers, so no network for
  ordinary URLs) handles: **Apple News** (`apple.news`) — fetch the page, parse
  the `redirectToUrlAfterTimeout("<url>")` JS call (its `og:url`/canonical point
  at apple.news itself; News+ exclusives have no underlying URL → nil);
  **Google News** (`news.google.com`) — offline base64-decode of the classic
  `CBMi…` article id (the blob embeds the publisher URL as a substring), falling
  back to Google's internal `batchexecute` RPC for new-style ids; **link
  shorteners** (`t.co`, `nyti.ms`, `flip.it`, …) — HEAD-follow the redirect to the
  final cross-host URL; **Facebook redirects** (`facebookRedirectTarget`,
  pure/offline — the target travels inline): `fbrpc://…/f?…&target_url=…` deep
  links (shared out of the FB app, read `target_url`) and `l.facebook.com` /
  `lm.` / `m.` / `facebook.com` `/l.php?u=…` link shims (read `u`), returning the
  percent-decoded http(s) target on a non-Facebook host (the `fbrpc` check runs
  BEFORE the http-host gate since the deep link has no http host; `fbclid` is then
  dropped by `ArticleFetcher.canonicalForArchiving`). The unwrap CHOKE POINT is
  `URLUnwrapper.unwrap` (the extensible `[WrapperHandler]` registry over these
  pure parsers), run ONCE at the top of `IngestPipeline.process` on EVERY surface
  (and once more in `ingest` to repoint the row via `store.updateURL`, dropping
  the item if the unwrapped article is already saved — the pipeline re-unwrap is
  then idempotent). Pure parsing is unit-tested (`NewsAggregatorUnwrapperTests` +
  `URLUnwrapperTests`); a hard-paywall publisher behind a wrapper (e.g. `nyti.ms`
  → nytimes.com) routes to the archive CAPTCHA as usual. **fbrpc entry-point
  gate**: an `fbrpc://` deep link has no http scheme, so a SAVE ENTRY POINT's
  `hasPrefix("http")` input gate would drop it before the pipeline runs.
  `URLUnwrapper.unwrapOffline(_:)` (sync/pure — resolves the offline handlers:
  Facebook deep link/shim + classic Google News) applies it up front at
  `ShareViewController.handleURL` / `handleJavaScriptResult`,
  the in-app Save-a-Link alert (via `normalizedTypedURL`, which ALSO validates the
  scheme), and every app intent via `IntentIngestHelper.handleSavePressWithTimeout`.
- **Platform items**: the pipeline's `Classifier` recognizes a platform URL
  (X/Bluesky/Reddit/TikTok/IG/FB/Spotify/Apple) BEFORE any fetch —
  `Outcome.social`/`.video` → `IngestorOutcomePresenter` routes to
  `ingestPlatformItem`/`handleVideo` → a `.ready` no-content item, NEVER `.failed`
  or text-extracted. Rendering goes through `PlatformRegistry.module(for:)`.
  `SavedItem` carries `platform`/`platformItemID`. See `content-platforms.md`.
- `LunaFetch/ArticleFetcher.swift` — `URLSession` GET with the Safari UA by
  default. The Googlebot crawler UA (soft-paywall bypass: crawler UA + no JS) is
  NOT the default fetch — it's an explicit `.userAgent(.googlebotDesktop)`
  `BypassStrategy` (`readers.md`'s bypass-plan section). The hard-paywall fallback
  runs through `BypassPlan`'s silent chain, which reaches the **Wayback Machine**
  (`archive.org/wayback/available` → replay snapshot; automation-friendly, no
  CAPTCHA) via `.waybackRaw`, then **archive.today**
  (`archive.ph/newest/<url>`; user-submitted snapshots that bypass more paywalls
  but rate-limit/CAPTCHA datacenter IPs with HTTP 429) as the WKWebView-only
  terminal stage.
- **Shared pipeline** (`LunaIngest/IngestPipeline.swift`): `IngestPipeline
  .process(_ input: IngestInput, timeout:…, …) async -> Outcome` is the SINGLE
  entry every surface calls. `IngestInput` = `url` + `source: CaptureSource` +
  optional `documentType`/`prefetchedHTML`/`forceArticle`. `Outcome`
  (EXHAUSTIVE): `.article(content, html:)` | `.product(ProductInfo, html:)` |
  `.social(platform, itemID:)` | `.video(platform, itemID:)` | `.document(type:)`
  | `.needsArchive(title:)` | `.failed(SaveFailureReason?)` |
  `.unsupported(owner:)` (the classifier demanded a kind this app's target
  doesn't link — the compile-time surface split; the central Luna app registers
  every processor and never produces it). Order: `URLUnwrapper.unwrap` ONCE →
  `Classifier.classify` (platform/video/document FIRST, before any fetch) →
  per-kind processing — all wrapped in ONE overall timeout (`processTimeout = 28s`)
  so it can never hang (on timeout → `.needsArchive` for a hard-paywall host, else
  `.failed`). Deterministic news classifications are authoritative in both
  ingestion and `BypassGate`: known free/paywalled publishers skip heuristic
  product detection, preventing embedded store cards, subscription offers, or
  generic commerce component state from recategorizing the primary article or
  suppressing its unlock plan (the New Yorker regression); known shops remain
  trusted products and only `.undetermined` pages use product heuristics. A
  title-less background-fetch rejection also becomes `.needsArchive` when the
  selected `BypassPlan` has a browser pre-stage: this is how Reuters' DataDome
  `401` reaches its direct-unlock WKWebView/script-blocking rule instead of being
  terminally marked failed before the browser tier runs. Unknown hosts with no
  browser recovery remain `.failed`. Identical for the main-app ingestor AND both
  share-sheet extensions + intents + friend receive; they differ only in their
  `OutcomePresenter`. `render` defaults nil (extension-safe — no WebView); the
  main app injects `WebViewPriceRenderer`. Dep-free (compiles in the extensions).
  See `readers.md`. Tests: `IngestPipelineTests` + `OutcomePresenterTests`.
- **Safari parity:** `LunaSafari/Resources/content.js` consumes the generated
  shared news-host table before deciding which pill to show. Known news
  publishers therefore skip Safari's product heuristic too, so publisher
  commerce/subscription furniture cannot produce a "Track in Luna" pill. With
  on-device unlock enabled, the generic cleanup removes content-less paywall
  overlays and unhides article nodes carrying the `paywall` class (the New Yorker
  full-body shape), allowing the article to unlock in place before "Read in Luna"
  captures the rendered HTML.
- `LunaPaywallBypass/ArticleResolver.swift` — `resolve(url:prefetchedHTML:)` →
  `ArticleResolution` (`.readable(content, html:)` | `.paywalled(title:)` |
  `.unreadable`). Called by `IngestPipeline`'s web-processing branch;
  `prefetchedHTML` reuses the product-detection fetch. Tries the direct fetch,
  then `fetchArchivedHTML`; returns readable content from either, else the best
  non-placeholder title found — preferring the direct page's title (FT serves a
  titled subscription stub), falling back to the archive snapshot's (WSJ 401s with
  no title directly, but its Wayback snapshot still carries one) — so a paywalled
  item can be labeled and parked in `.needsCaptcha`. The pure decision is split
  into `resolution(direct:archived:)` (`ArticleResolverTests`). The archive.today
  URLSession leg uses a short 12s timeout (it almost always CAPTCHAs → fall
  through fast, don't stall the share sheet).
- `ArticleContent.hasReadableBody` = ≥1200 chars of block text AND
  `!looksPaywalled`. **`looksPaywalled`** = high-precision gate phrases at any
  length (`to continue reading`, `subscribe to read`, …), or weaker
  subscription-marketing phrases only in a SHORT body (<2500 chars: `try unlimited
  access`, `complete digital access`, `cancel anytime`, `subscriber agreement`,
  `personal, non-commercial use`, …). HTML-level locks
  (`isAccessibleForFree:false`, premium/metered `article:content_tier`) also
  reject only short/teaser-shaped bodies; long gate-free article prose wins even
  if the publisher labels it subscriber-only (New Statesman-style full HTML). This
  catches BOTH the FT marketing interstitial and the WSJ Wayback teaser while
  avoiding archive fallback for complete subscriber-marked responses. Tested in
  `ArticleContentPaywallTests`, `PaywallDetectorTests`, and
  `ArticleExtractionTests`.
- **Hard paywalls** (`needsCaptcha`): when `ArticleResolver` gets a title but no
  readable body, the ingestor calls `store.markNeedsCaptcha` → state
  `.needsCaptcha`, shown with a **lock** thumbnail + **"tap to unlock"**.
  Tapping opens `LunaArchiveReader/ArchiveWebReaderViewController` — a `WKWebView`
  loaded to `archive.ph/newest/<url>` (URL pre-filled in the PATH, so the user
  never types it). archive.today gates many clients behind a **Cloudflare
  reCAPTCHA** that issues a `cf_clearance` cookie **bound to the exact
  User-Agent**; the view sets a fixed real-mobile-Safari `customUserAgent` (the
  default WKWebView UA omits the `Safari/` token → Cloudflare re-challenges after
  every solve = the infinite-CAPTCHA loop) and uses the persistent `.default()`
  cookie store (one solve unlocks later articles too). `isChallengePage` (detects
  `/cdn-cgi/l/chk_captcha`) prevents extracting the challenge page.
  **archive.today rate-limits by IP with HTTP 429 and won't honor CAPTCHA solves
  until it cools (device logs confirmed: the UA fix is live but solving still
  429-loops — it's an IP/network block on the only full-text source, not a webview
  bug, and not client-side-fixable).** So after `challengeCount >= 3` consecutive
  429s the view hides the dead challenge and shows **actionable guidance** (wait
  ~30 min / switch network or VPN / open in Safari with content blockers
  disabled — Safari passes the CAPTCHA, blocked only by the user's ad blocker). A
  **Safari escape-hatch** button (`onOpenInBrowser`, main-app-only) opens the
  archive URL in real Safari. Per-step `SharedDiagnosticLog` lines (`[archive] …`,
  incl. per-main-frame `navAction type=`) make on-device loops self-diagnosing.
  Once a real snapshot loads (`innerText.length > 1500`, not a challenge page) it
  extracts the article off the DOM and `saveContent` flips it to `.ready`.
  `onClose`/`onExtracted` injectables let extensions complete their request / show
  a checkmark.
- `LunaHTMLClassification/ArticleExtractor.swift` — SwiftSoup mini-readability:
  strips `script/style/nav/header/footer/aside/form/iframe/svg/button`, scores
  parents by direct `<p>` text length, emits ordered blocks
  (`paragraph|heading|quote|listItem|image|caption|tableOfContents`) with UTF-16
  inline link ranges, plus `author`. LAYERED, never fails while any text exists:
  refined (junk class/role stripping + trailing link-farm trimming; used only when
  ≥350 chars AND ≥1/3 of basic) → basic (structural-tag stripping only) → JSON-LD
  `articleBody` override (when it dwarfs the DOM result — React sites ship the
  article as metadata) → raw body text. Container scoring credits ancestors with
  decaying weight (readability-style) so per-paragraph div wrappers still resolve
  to the article container; the winner is then WIDENED upward until it covers ≥60%
  of the document's paragraph text (CMSs that split the body across sibling slice
  containers, e.g. itsnicethat).
- `LunaModels/ArticleContent.swift` — the extracted content model (blocks + link
  ranges), persisted as `Articles/<uuid>.json`.
- **Price tracking** (`claudedocs/price-tracking.md`): a saved/pasted product URL
  with a real price becomes a **price tracker** (watch N store URLs, alert on a
  price drop) instead of an article. Its payload is the `price_trackers` /
  `tracker_stores` / `tracker_price_points` rows hanging off the save.
- `LunaSavesUI/SavesSectioning.swift` — **pure** (UIKit-free, unit-tested)
  bucketing: `Section`/`ListFilter` enums (stable raw values 0/2/3/4/5),
  `assignSections(items:now:)` (Reading/Archive/Error buckets, 7-day `archiveAge`
  strict-`>` cutoff), `shouldShowFilter(items:)`, `rendersAsReader(_:)`,
  `isFailedSave(_:)`. The decks and the audio queue delegate to these so every
  surface orders saves the same way.
- `LunaStorage/SafariURLStore.swift` — reads `lastSafariURL` /
  `lastSafariURLDate` App Group defaults written by the LunaSafari extension.
- **Pasteboard**: paste lives permanently on the util card's own paste row
  (`claudedocs/util-card.md`); the synthetic leading paste card and its
  probes/policies are gone. `PasteboardSuggester` (LunaSaves) survives because
  the util card's `RecentURLMatcher` still uses its `platformPreviewArt` hook.
- **Hard paywalls in the extensions** (`ShareSurfaceDriver.presentArchive` +
  `ArchiveWebReaderViewController`, see `readers.md`): EVERY surface gets the same
  `Outcome` from the shared `IngestPipeline` and, on `.needsArchive`, marks
  `.needsCaptcha` and presents the SAME `ArchiveWebReaderViewController` directly
  (enforced by `SurfaceParityTests`). The action ext swaps to the in-sheet native
  reader on extract; the share ext confirms. On `.failed` → the action ext shows
  an ERROR (never a misleading "Saved"), the share ext marks the item failed +
  completes quietly for the app to retry. Done completes the extension. The whole
  call is bounded by the pipeline's overall timeout, so the action extension can
  never spin forever.
- `LunaShare/` — share extension (`com.hsanabria.luna.share`,
  `NSExtensionPointIdentifier` = `com.apple.share-services`, activation: 1 web URL
  or 1 file).
- `LunaAction/` — action extension ("Read in Luna"; per-host bundle id
  `<host-app-bundle-id>.action2`, `NSExtensionPointIdentifier` =
  `com.apple.ui-services`, `NSExtensionPrincipalClass` =
  `$(PRODUCT_MODULE_NAME).ShareViewController`, activation: 1 web URL or 1 file).
  Same `LunaShareSurface` code as the share extension; appears as a separate
  share-sheet action row and opens the reader (articles) or a playback/open-in-app
  screen (non-textual). Own App Group entitlement + per-surface transparent
  action-icon template appiconset, generated by extracting and monochroming the
  foreground artwork from each 1024px `AppIcon*` master. **Ships `GetURL.js` +
  `NSExtensionJavaScriptPreprocessingFile`**: a `com.apple.ui-services` action
  extension gets no usable web URL from Safari without it — the URL arrives as the
  JS result in a `UTType.propertyList` attachment
  (`NSExtensionJavaScriptPreprocessingResultsKey` → `{URL,title}`), which
  `ShareViewController.handleJavaScriptResult` reads. `public.url`/file branches
  still cover non-Safari hosts.
  - **Which attachment either extension consumes** is decided by the pure
    `ShareAttachmentRouter` (`LunaShareSurface`, unit-tested by
    `ShareAttachmentRouterTests` — the live share sheet has no test seam), from
    what the providers ADVERTISE (`registeredTypeIdentifiers`), never from their
    loaded values: web link → document (pdf/rtf/plain-text/text) → bare file URL →
    text, and the chosen route is logged next to the advertised types
    (`route=url@0`) in the shared diagnostic log. A **web link is `public.url`
    WITHOUT `public.file-url`** — that file-URL exclusion, not "advertises no
    document type", is what separates a link from a file: hosts commonly register
    ONE provider for both the link and a plain-text rendering of it, and the old
    "any document type wins" rule imported those shares as `.txt` documents, so a
    shared video was dropped by Downloader as Reader-owned and stored by
    Luna/Reader as an unreadable document (`lunadoc://…` titled "text").
  - **Plain text that is NOT a file routes to `.text`, where a link inside it
    wins** (`handleText`): hosts that hand over a link as text commonly caption
    it — the YouTube share sheet sends `<video title>\n<link>` — so
    `ShareTextURL.firstLink` accepts a link with up to `shortTextLimit` of caption
    around it, alongside the stricter `ShareTextURL.extract` ("the text IS just a
    link") that a text FILE still uses. Text with no link, or a document's worth of
    prose around one, still imports as a document — titled from its first line
    rather than the provider's generic "text". Rich text (`.rtf`) and in-memory
    PDFs stay documents.

## Tests

`LunaTests/SavesDatabaseTests.swift` is the store's cross-process contract: two
connections on one file, a writer that never commits, the enum tolerance four
independently-updated apps depend on, and the foreign keys that make deleting a
save delete everything hanging off it.
`LunaTests/SavedFileOwnershipTests.swift` covers the triggers, the crash-safe
queue and the reaper, reading every assertion through a SECOND connection the way
another process would. `LunaTests/SavesStoreCacheTests.swift` pins the
`data_version` cache and the no-op-mutation skip.
`LunaTests/SavesIngestorSurfaceTests.swift` and
`LunaTests/SavesIngestorTrackerDedupTests.swift` cover the ingestor's per-app drop
gate and its re-save dedup; `LunaTests/ArticleExtractorTests.swift` covers
extraction.

## Bulk import / export

Settings ▸ Import & Export shares every link as one `section,url` CSV (the
archive as its own section) and reads one back through a review sheet, a bounded
parallel ingest, and a browser pass over anything hard-paywalled. The import goes
through `store.insertImported` + `SavesIngestor.ingest`, NOT `handleSavePress` —
so it is not a save press and fires none of the new-save automation. Full design:
`claudedocs/import-export.md`.

## Failed saves

A `.failed` save shows a real error card on every card root — the page itself in
a web view, the URL that failed, a red rim, and the chat hand-off row. It has no
kind, so it surfaces in EVERY app, and its menu offers Share Link + Delete only
(no Archive). Full design: `claudedocs/failed-saves.md`.

## Failed-save recovery

A `.failed` save is not a dead end, and it asks the user for nothing. Apple
Intelligence gets ONE silent, automatic attempt per item, tracked in the
`rescueLedger.json` sidecar; the extensions queue that attempt for the app in
`PendingRescueRequestStore`, with no tap involved. What the user can do is the
chat hand-off on the card: ChatGPT or Claude answers with a Luna file, and Luna
imports it. Full designs: `claudedocs/url-rescue.md`,
`claudedocs/llm-handoff.md`, `claudedocs/luna-file.md`.
