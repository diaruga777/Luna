# Document Import

Documents (PDF, TXT, Markdown, RTF, and any `public.text`) shared to Clip from
the system share sheet are parsed into reading-list articles with **no web
URL**. They can be read in both readers and sent to Kindle, but cannot be
shared to friends or via the system share sheet (no URL).

## Flow

1. **Share extension** (`ClipShare`): activation rule now also matches files
   (`NSExtensionActivationSupportsFileWithMaxCount`). `ShareViewController`
   prefers a web URL; otherwise takes the first attachment conforming to
   `.pdf`/`.rtf`/`.plainText`/`.text` and `loadFileRepresentation`s it.
   `SharedReadingListAppender.appendDocument` copies the file into the App
   Group at `Articles/<id>-source.<ext>` and appends a pending item with
   `urlString = clipdoc://<id>`, `documentType = ext`, `title = filename`.
2. **Ingestor** (`ReadingListIngestor.ingestDocument`): on next launch/
   foreground, parses the source file via `DocumentParser` into
   `ArticleContent`, saves it (state → ready), and fires the Kindle
   becameReady hook (documents are Kindle-eligible).

## Model

`ReadingListItem.documentType` (`decodeIfPresent`, mirrored in the appender) →
`isDocument` / `canShareToFriends` (false for docs). Identity is the synthetic
`clipdoc://<uuid>` (`ReadingListItem.documentURLString(id:)`). `store.delete`
removes the `-source.<ext>` file too.

## Parsing (`Clip/Documents/DocumentParser.swift`)

- PDF → PDFKit page text → `PlainTextParser`.
- RTF → `NSAttributedString(rtf)` → `PlainTextParser`.
- TXT / public.text → `PlainTextParser` (paragraphs split on blank lines,
  single newlines collapsed to spaces).
- Markdown → `MarkdownParser` (ATX `#` headings, `>` quotes, `-`/`*`/`+`/`1.`
  list items, else paragraphs).

## UI gating

- List row: leading subtitle shows the type (e.g. "PDF") instead of a host.
- Context menu: documents show **Send to Kindle** only (no Send to Friend).
  Videos show Send to Friend only. Articles show both.
- Reader: the share button is hidden for documents.

## Tests

`DocumentParserTests` (PlainText/Markdown pure parsers + txt round-trip +
empty → nil). PDF/RTF paths verified in the simulator.
