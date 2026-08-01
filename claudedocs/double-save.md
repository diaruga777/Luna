# Double Save Articles (Action Button only)

Saving the exact same ARTICLE URL twice within 7 seconds through the Action
Button intents performs the action the user picked in **Settings → Shortcut &
Safari → Double Save Articles**. Three choices, in picker order:

| Choice | What the second press does |
| --- | --- |
| **Nothing** (default) | No-op. |
| Send to Kindle | Emails the article's EPUB to the configured Kindle address. |
| View immediately | Returns a self-contained `.rtfd` Rich Text document package from the App Intent, ready for Quick Look. |

Nothing is the default because a double save is easy to trigger by accident.
This behavior is strictly article-only: videos, social posts, audio, products,
and imported documents ignore the second press.

The setting exists only in the two apps that can act on it — **Luna** (central)
and **Luna Reader**, the two that link `LunaSend` — and is stored **per app**
(`DoubleSaveActionStore`, keyed by `LunaApp.storageIdentifier`), so each keeps
its own. Downloader and Price Tracker never show the section and never arm the
regime (`ActionButtonIntentSupport.doubleSaveSurface` is nil there).

No other save surface uses this regime. Share/action/Safari extensions, paste,
manual add, mail import, and every in-app save keep normal save semantics.

`SaveIntent` also detects a repeated screenshot by digest. A visually similar
screenshot inside the same seven-second window re-runs the previous save without
another model call, so it reaches the same decision.

Intent timing is captured at the very start of `perform()`, before setup,
Foundation Models, search, or ingest work. Once the URL resolves,
`ReadingListStore.reserveSaveAttempt` atomically performs URL lookup + initial
insert/press-timestamp update in one cross-process coordinated mutation. Two
overlapping intent runs therefore cannot both observe an absent URL and behave
as first saves. The policy compares the absolute distance between the two start
times and has **no minimum gap**: zero-gap starts and starts whose store-arrival
order is reversed both count, provided they are less than seven seconds apart.

## Flow

The Action Button intents pass a non-nil `doubleSaveActionSurface` through
`IntentIngestHelper` to `ReadingListIngestor.handleSavePress`.
`resolvedIntentAction` turns the stored `DoubleSaveAction` into a
`SavePressPolicy.IntentAction`, and **never returns nil** — an Action Button save
always stays in the 7 s intent regime rather than falling through to the legacy
12 s one. "Nothing", and a Kindle that isn't configured, both become
`.doNothing`.

A repeat inside `intentDoublePressWindow` (7 s) then becomes:

- `.sendToEreaders([kindle])`, retaining the 24-hour resend cooldown; or
- `.exportArticle(format: .richText)` →
  `SavePressResult.exportRequested(item, .richText)`.

**The file is not built in the ingestor.** Serialization lives in `LunaSend`, an
article-kind module that the universal `LunaReadingList` / `LunaIntents` can't
link, so the press only *asks*: the outcome reaches the intent as
`IntentIngestHelper.ActionButtonSaveOutcome.exportRequested(item:format:)`, and
`ActionButtonIntentSupport.exportFile` builds it through the
`articleExporter` seam that `KindWiring+Luna` / `KindWiring+Reader` install
(`ArticleExportService().writePreparingImages(format, for:)`).

The exporter uses `writePreparingImages`, so a double save taken seconds after
the save still returns a file WITH the article's pictures — see
article-export.md's "Images: resolved, then fetched"; without it the 7-second
window always beat the image downloads.

The returned document becomes the intent's **media** — `SaveResultEntity.media` /
`ProvideContextResultEntity.media` — replacing the media download for that run
(an article has none anyway). An export that can't be built returns no file
rather than throwing: a double save must never fail the save that preceded it.

Platform items (videos, posts, tracks) are excluded from both the Kindle and the
export actions — neither has an EPUB target nor stored article content.

The older 12-second in-app regime remains for a configured ereader destination
whose capture-source mode is `.doubleSave`; it also only sends to that ereader.
It is now unreachable from an Action Button save.

Legacy `DoubleSaveActionStore` values may remain in an existing App Group. The
retired `openPDF` and `openMarkdown` values migrate to `.openDocument` (View
immediately). The retired `sendToFriend` action no longer decodes and reads back
as `.nothing`; the friend-prompt hand-off and preset-email storage survive
unused, and pending contact prompts are not consumed on foreground.

## Why RTFD for "View immediately"

The previous flat `.rtf` did contain standard hex-encoded `{\pict}` JPEG/PNG
payloads, but Apple's RTF importer/Quick Look ignores those groups. That made the
document appear picture-less even though Word and LibreOffice could read the
same bytes. Apple's own flat-RTF writer likewise documents that it omits
attachment attributes.

RTFD is Apple's native Rich Text with Attachments document package and Quick
Look renders it. `ArticleRTFBuilder` now returns a `FileWrapper` containing:

- `TXT.rtf`, with live `HYPERLINK` fields and relative `\NeXTGraphic` entries;
- one `LunaImage-NNN.jpg|png` sibling per resolved picture, containing a COPY of
  the actual bytes (unsupported formats/GIF animations become PNG stills); and
- explicit `\widthN \heightN` display geometry in twips on every attachment.

No attachment path points at Luna's App Group/Documents directory. Moving the
`.rtfd` package away from Luna therefore keeps every picture readable.

## Settings UI

`ShortcutSettingsScreen` (universal, `Luna/Settings/SettingsViewController.swift`)
draws the three-choice picker as a pull-down menu button. It sits inside the same
`#available(iOS 27.0, *)` gate as the rest of
the Action Button shortcut setup (app-intents.md): below iOS 27 there is no
shortcut section, so there is nothing for a double save to be a behavior of.
Picking "Send to Kindle" without a configured Kindle offers the setup it
needs through `DoubleSaveSettingsSupport.kindleSetupLauncher` (article-only
screens, installed by the same two `KindWiring` variants), and **keeps the
choice** either way: it goes live the moment Kindle is set up, and does nothing
until then.

## Tests

- `DoubleSavePolicyTests` — the seven-second boundary, zero-gap and reverse-order
  overlapping starts, the Kindle cooldown, platform-item exclusion, and that
  `.doNothing` never falls back to the legacy ereader send.
- `DoubleSaveActionStoreTests` — the `.nothing` default, per-surface
  independence, retired-value migration, and the single document action →
  `ArticleExportFormat.richText` mapping.
- `ReadingListStoreCacheTests` — atomic first-invocation reservation across
  concurrent store instances and monotonic timing state.
- `SavePressPolicyTests` — the older in-app ereader regime.
- `ArticleDocumentBuilderTests` — RTFD package structure, copied/decodable image
  bytes, explicit dimensions, no Luna paths, and a system-reader round trip.
