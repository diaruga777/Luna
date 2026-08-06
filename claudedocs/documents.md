# Document Import

Documents (PDF, **EPUB**, **Word `.docx`**, RTF, **HTML**, TXT, Markdown, and
any `public.text`) shared to Luna from the system share sheet are parsed into
reading-list articles with **no web URL**. They can be read in both readers and
sent to Kindle, but cannot be shared to friends or via the system share sheet
(no URL).

**The import set is the export set.** EPUB and `.docx` are the two formats Luna
already writes (`EpubBuilder`, `ArticleDOCXBuilder`) — a piece that left Luna to
be read on an ereader or edited in Word can be shared straight back in, and a
book from anywhere else arrives on the same path. They are containers, not
markup: `ZipArchiveReader` (LunaModels, the counterpart to the writer the
exporters use) reads them.

Documents are Reader-owned, so the per-app gate is the usual one — **Luna and
Luna Reader accept them; the Downloader and Price Tracker drop them** with the
unsupported-save card (`saveDocumentDirectly`, `surface-support.md`).

## Flow

1. **Share extension** (`LunaShare`) and **action extension** (`Luna Action
   Extension`): both activation rules match files
   (`NSExtensionActivationSupportsFileWithMaxCount`) and share the same
   `ShareKit/ShareViewController`. It prefers a web URL; otherwise takes the
   first attachment matching `ShareAttachmentRouter.documentTypes` and
   `loadFileRepresentation`s it.

   **That list is MOST SPECIFIC FIRST, and the order is load-bearing.** `.html`
   conforms to `public.text`, so a supertype-first order imports a saved web
   page as a wall of raw markup. EPUB and `.docx` conform to neither `.text` nor
   `.data`'s readable half, which is why they had to be named at all: before
   they were, an ebook fell through to the bare-file-URL leg and was stored with
   `documentType = "epub"` that nothing could parse.

   `.html` is in `textTypes` too, and that asymmetry is deliberate: an HTML
   **file** is a saved page and imports as one, while an in-memory HTML payload
   is a host rendering a link it is sharing, so it stays on the text leg where
   the link inside wins.
   `SharedReadingListAppender.appendDocument` copies the file into the App
   Group at `Articles/<id>-source.<ext>` and appends a pending item with
   `urlString = lunadoc://<id>`, `documentType = ext`, `title = filename`.
2. **Ingestor** (`ReadingListIngestor.ingestDocument`): on next launch/
   foreground, parses the source file via `DocumentParser` into
   `ArticleContent`, saves it (state → ready), and fires the Kindle
   becameReady hook (documents are Kindle-eligible).

## Model

`ReadingListItem.documentType` (`decodeIfPresent`, mirrored in the appender) →
`isDocument` / `canShareToFriends` (false for docs). Identity is the synthetic
`lunadoc://<uuid>` (`ReadingListItem.documentURLString(id:)`). `store.delete`
removes the `-source.<ext>` file too.

## Parsing (`LunaDocuments`)

`DocumentParser.parse(fileURL:type:title:)` switches on the stored extension.
`readableExtensions` is the same set as a list, pinned to the router's UTTypes
by `EbookDocumentImportTests`.

- PDF → PDFKit page text → `PlainTextParser`.
- RTF → `NSAttributedString(rtf)` → `PlainTextParser`.
- TXT / public.text → `PlainTextParser` (paragraphs split on blank lines,
  single newlines collapsed to spaces).
- Markdown → `MarkdownParser` (ATX `#` headings, `>` quotes, `-`/`*`/`+`/`1.`
  list items, else paragraphs).
- HTML / XHTML → `MarkupBlockExtractor`, and the page's own `<title>` replaces
  the file name.
- **EPUB** → `EpubDocumentParser`. `META-INF/container.xml` names the OPF (a
  book may put it anywhere — it is never guessed), the OPF's manifest maps ids
  to hrefs resolved against the OPF's OWN directory with percent-escapes undone
  and `..` collapsed, and the spine gives the reading order. `linear="no"`
  items (the copyright page a reading system reaches only from a link) are
  skipped. The whole book becomes ONE item: that is what a reading-list save is,
  and it is what makes an imported book work with RSVP, read-aloud, export and
  Kindle unchanged. A chapter that names itself only in its `<title>` gets that
  as a heading, so consecutive chapters do not run together.
- **`.docx`** → `DocxDocumentParser`, reading `word/document.xml` directly.
  Not `NSAttributedString`: iOS has no Office Open XML document type (that
  initializer is AppKit's), and the paragraph STYLE — `w:pStyle`, `w:numPr` —
  is the only thing that says which lines are headings and lists. Runs are
  joined from their `w:t` text nodes RAW, because SwiftSoup's `text()`
  normalizes away the trailing space (`xml:space="preserve"`) that separates one
  run from the next.

Both container formats carry their own title and author (`dc:title` /
`dc:creator`, `docProps/core.xml` for Word), which beat the shared file's name —
a book's file name is a distribution artifact. `saveContent` copies that title
onto the reading-list row.

`MarkupBlockExtractor` is the shared markup back end (EPUB chapters + the HTML
import). It is deliberately NOT the web article extractor: that one's job is to
find an article inside a page full of navigation and promos, and it SCORES
candidates to do it — the wrong instinct when the file IS the content and a
short chapter would lose to nothing at all. It takes the document's own
block-level elements in document order, drops `script`/`style`, lets the OUTER
element win when they nest (a `p` inside a `blockquote` is one quote, not two
blocks), and falls back to the plain-text parser for a document that lays its
prose out in bare `div`s — which badly made ebooks do.

`ZipArchiveReader` reads the CENTRAL DIRECTORY rather than walking local headers
from the front: a local header may leave both sizes at zero and defer them to a
data descriptor after the payload, so the front of the file cannot always say
where an entry ends. Stored and deflated entries (raw DEFLATE via
`COMPRESSION_ZLIB`); ZIP64, encryption and multi-disk return nil rather than a
partial read.

## UI gating

- List row: leading subtitle shows the type (e.g. "PDF") instead of a host.
- Context menu: documents show **Send to Kindle** only (no Send to Friend).
  Videos show Send to Friend only. Articles show both.
- Reader: the share button is hidden for documents.

## Tests

`DocumentParserTests` (PlainText/Markdown pure parsers + txt round-trip +
empty → nil). PDF/RTF paths verified in the simulator.

`EbookDocumentImportTests` covers the zip reader, both container parsers and the
markup extractor. Its fixtures are built with `ZipArchiveWriter` — the same
writer that produces the books Luna exports, so the round trip is the test and a
hand-carved byte blob would only assert the test file's idea of a zip. The one
exception is the deflate fixture, assembled by hand because the writer only
stores: `NSData.compressed(using: .zlib)` is Apple's `COMPRESSION_ZLIB`, which
despite the name is raw DEFLATE with no header or trailer — exactly a zip
entry's payload, appended verbatim.

`ShareAttachmentRouterTests` covers the routing: EPUB/`.docx` as documents, an
HTML file as `.html` rather than by its `public.text` supertype, and an
in-memory HTML payload still on the text leg.
