# Article Export (Export as…)

A universal, credential-free way to get a saved article out of Luna: build the
article in the format the user picks and hand the file to the system share sheet.
Four formats — **EPUB, PDF, Markdown, plain text** — offered on any saved article
whose content is unlocked (extracted and stored). Available in the two apps that
link `LunaSend`: **Luna** (central) and **Luna Reader**.

A fifth serializer, **Rich Text (`.rtf`)**, exists but is NOT in this menu: it is
the double save's "Open Document" action only (double-save.md).

## Key files

`LunaLibraries/Sources/LunaModels/ArticleExportFormat.swift`:
- `ArticleExportFormat` — `.epub / .pdf / .markdown / .plainText / .richText`,
  carrying the `fileExtension`, `displayName`, and `systemImage`. It lives in
  **LunaModels** (the bottom layer) because the two ends sit in different link
  groups: `LunaSend` builds the bytes and is an article-kind module, while
  `LunaSocialUI` draws the options and is universal. `allCases` is the
  SERIALIZER list; **`shareMenuFormats` is the menu**, and its order IS menu
  order. They differ by `.richText`.

`LunaLibraries/Sources/LunaSend/ArticleExportService.swift`:
- `write(_:for:) throws -> URL` — serializes the format and writes it to a temp
  file named via `ArticleSendCoordinator.fileName(forTitle:extension:)`. Throws
  `ExportError.noContent` when the item has no stored content — the one gate
  that keeps still-locked and media items out of **every** format. Heavy —
  call off-main.
- `writeEPUB(for:)` — thin alias of `write(.epub, for:)`, kept because the
  email/Kindle send path names the EPUB specifically.
- `itemProvider(_:for:)` — `NSItemProvider(contentsOf:)` over the temp file, so
  the UTType (`org.idpf.epub-container`, `com.adobe.pdf`,
  `net.daringfireball.markdown`, `public.plain-text`) is inferred from the
  extension.
- `presentShareSheet(_:for:from:sourceView:)` — builds off-main, then presents
  `UIActivityViewController` (or an alert if there's no content).

Serializers, one per format, all taking `ArticleContent`:
- `LunaEpub/EpubBuilder` — EPUB 3, images embedded from the Articles directory.
  Also what Send to Kindle emails (see send-to-kindle.md).
- `LunaSend/ArticlePDFBuilder` — US-Letter PDF, images inline.
- `LunaSend/ArticleMarkdownBuilder` — CommonMark.
- `LunaSend/ArticlePlainTextBuilder` — UTF-8 prose.
- `LunaSend/ArticleRTFBuilder` — hand-written RTF, images embedded as `{\pict}`
  and links as `{\field HYPERLINK}`. Double-save only; see double-save.md for
  why the markup is emitted directly instead of via `NSAttributedString`.

## What each format keeps

|  | Images | Inline link destinations | Layout |
| --- | --- | --- | --- |
| EPUB | embedded (downloaded bytes, **animation kept**) | yes (`<a href>`) | reflowable |
| PDF | embedded (downloaded bytes, GIF → first frame) | styled, **not clickable** | fixed, paginated |
| Markdown | referenced by remote URL | yes (`[label](url)`) | flat text |
| Plain text | `[Image: alt]` placeholder | no | flat text |
| Rich Text | embedded (PNG/JPEG blip; everything else → PNG still) | yes (`HYPERLINK` field) | reflowable |

Deliberate choices behind that table:

- **Markdown images point at the ORIGINAL remote URL** (`imageURLString`), not the
  downloaded file. A `.md` is a single flat file with nowhere to put bytes, so a
  local-file reference would dangle the moment it leaves Luna's container. An
  image block Luna never resolved a URL for is dropped, not emitted broken.
- **Plain text carries no URLs in the body.** The point of `.txt` is prose with
  nothing in the way; Markdown is the format that preserves destinations. Only
  the article's own source URL appears, in the header.
- **PDF links are styled but not clickable.** TextKit drawing into a PDF context
  emits glyphs, not link annotations.
- **In-page `#chapter` jumps are never rendered as links** in Markdown or PDF —
  a standalone flat file has no in-document destination for them. (The EPUB *does*
  keep them: it preserves each block's `anchorID`, so the article's own chapter
  marks stay live navigation inside the book.)

## PDF specifics

`ArticlePDFBuilder` paginates with **TextKit 1**: one `NSTextContainer` per page
hung off a single `NSLayoutManager`, which is the only layout path that both
breaks lines exactly where the drawn page will and draws `NSTextAttachment`
images for free. `UIGraphicsPDFRenderer` then draws each container onto its own
page, and `documentInfo` gets the title/author.

- Colours are **hard-coded black-on-white**, not `LunaColors`: the file leaves the
  app, so it must not inherit Luna's near-black sky (both Luna appearances are
  night — see visual-effects.md). Nothing here reads the trait collection.
- Image attachments are scaled to fit the text column and to at most 60% of a
  page's height. That bound matters: an attachment taller than a page would
  produce a container that lays out no glyphs, and `paginate` would loop forever
  adding pages. It also stops on a container that consumes nothing, and caps at
  500 pages.

## Images: resolved, then fetched

Exports used to come out with **no pictures**, and the builders were not at
fault — a PNG/JPEG/HEIC/GIF block does embed. They trusted
`block.imageFileName`, and that field is routinely nil when the picture is
already on disk (or fetchable):

- `ArticleIngestHandler.persistArticle` flips an item `.ready` after fetching
  only unknown-size images near the top; the rest download in a detached task
  and re-save **afterwards**. A double-save export (7 s window) always beat it.
- `ShareSurfaceDriver.persistArticle` (a share/action-extension save that never
  opens the reader), `saveNewWithContent` (paste), and `IncomingMailImporter`
  download no images at all.

So an export must not read the recorded name and stop. Two pieces:

`LunaModels/ArticleImageFiles` — the URL-hash file naming
(`img-<sha256 prefix>.<ext>`) and `localFile(for:in:)`, which falls back from
the recorded name to the hash-keyed file the downloader actually wrote. It sits
in LunaModels because the writer (`ArticleImageDownloader`, LunaReaderUI) and
the readers (`LunaSend`, `LunaEpub`) are in different link groups and **must**
agree — `ArticleImageDownloader` delegates its own naming here so there is one
definition. `ArticleImageReferer` picks the `Referer` an image fetch sends (the
article URL; an imported email or document falls back to the image's origin).

`LunaSend/ArticleExportImages.preparer` — the seam that FETCHES what still
isn't local, bounded by `preparationTimeout` (15 s). The downloader is
LunaReaderUI's, so each article app's `KindWiring` installs it; extensions leave
it nil and export from local files only. Work cut off by the timeout isn't
wasted — the files land on disk and the next export resolves them for free.

`ArticleExportService.writePreparingImages(_:for:)` is the form every
user-facing export calls (share sheet, the double save's App Intent return, and
`ArticleSendCoordinator`'s Kindle EPUB — an auto-send fires exactly when an
article becomes ready). It persists the enriched content via `saveContent`,
which also registers the new files with `ImageReferenceStore` so they aren't
collected as orphans. The plain synchronous `write` remains for callers with
nothing to fetch.

### Per-format image handling

- **EPUB** embeds an animated GIF **whole** — the only export format that can
  keep the animation. Non-core media types (WebP, HEIC, AVIF, and the `img`
  unknown-type fallback) are **transcoded to JPEG/PNG**; previously WebP was
  embedded as-is and the rest were dropped, and since WebP is not an EPUB core
  media type, Kindle's converter and most reading systems discarded it anyway.
  The chapter's `<img src>` points at the transcoded entry name.
- **PDF** has no animation: a GIF contributes its first frame.
- **Rich Text** has no GIF blip type (`\pngblip` / `\jpegblip` only), so a GIF —
  and WebP/HEIC/AVIF — is re-encoded as a PNG still rather than dropped.
- **Markdown** references the original remote URL (see above); **plain text**
  drops images by design.

## Entry points

Both go through `AppReaderShareProvider` (`Luna/Social/AppReaderProviders.swift`):

- Reading-list row long-press / reader share button → **"Export as…"**, a
  submenu of the four formats. Shown for ready articles/documents, not videos.
- A no-url text article (email/document) has no link to share, so its share
  button skips the option list and presents the format picker directly
  (`presentExportOnlyShare`).

`ReaderShareSheet.Row` (LunaSocialUI) carries `children` for this: a row with
children renders as a nested `UIMenu` off the share button, or — in the
bottom-sheet fallback — dismisses and presents a second sheet titled "Export
as…". Nesting keeps one row for a choice most shares never touch instead of
doubling the top-level list.

## On the "Options" format selector

The Photos-style in-sheet JPEG/HEIF "Options" toggle is a **private** system
affordance for `PHAsset` — **not available to third-party apps**. That's why Luna
picks the format *before* the sheet opens (one provider, one format). The
supported in-sheet equivalent — several representations on one `NSItemProvider` —
hands the choice to the receiving app instead of the user, which is the opposite
of what's wanted here.

## Tests

- `LunaTests/ArticleExportServiceTests.swift` — per-format extension/bytes/UTType,
  one shared file stem, `noContent` for every format on an item with no stored
  content, and the image preparation path (fetches, persists, skips when there's
  nothing to do, and survives no seam installed).
- `LunaTests/EpubBuilderImageTests.swift` — zip entries and manifest media types
  read out of the built book: hash-resolved images, the animation kept whole,
  non-core formats transcoded, one entry per repeated image, and a missing file
  skipped in the zip AND the chapter at once.
- `LunaTests/ArticleDocumentBuilderTests.swift` — Markdown block rendering,
  inline-link splicing, marker escaping, awkward-URL angle brackets,
  out-of-bounds link ranges; plain-text markup-freedom; PDF validity, media-box
  size, pagination, image embedding **counted as PDF image XObjects** (byte
  counts can't tell a picture from a blank line), hash-resolved images, GIF and
  every stored format surviving, off-main build; RTF brace balance, ASCII
  escaping, hyperlink fields, `{\pict}` embedding, and the share menu omitting
  it.
- `LunaTests/ReaderShareSheetTests.swift` — the export submenu's contents, order,
  and per-format callback, in both the menu and the row list.
