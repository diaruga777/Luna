# Article Export (Share eBook)

A universal, credential-free way to get a saved article onto any ereader/app:
build the article's EPUB and hand it to the system share sheet. Reaches Apple
Books, Kobo, reMarkable, Boox, Files, AirDrop, Mail, etc.

## Key file

`Luna/Export/ArticleExportService.swift`:
- `writeEPUB(for:) throws -> URL` — builds the EPUB via `EpubBuilder` (content +
  images from `ReadingListStore`) and writes it to a temp file named via
  `ArticleSendCoordinator.epubFileName(forTitle:)`. Throws `ExportError.noContent`
  for items with no extracted content (e.g. videos). Heavy — call off-main.
- `itemProvider(for:)` — `NSItemProvider(contentsOf:)` over the temp file, so its
  UTType (`org.idpf.epub-container`) is inferred from the `.epub` extension.
- `presentShareSheet(for:from:sourceView:)` — builds off-main, then presents
  `UIActivityViewController` with the file URL (or an alert if there's no content).

## Entry points

- Reading-list row long-press → **"Share eBook…"** (shown for ready articles/docs,
  not videos).
- Reader share sheet → **"Share eBook…"** option (see readers.md, Feature C).

## On the "Options" format selector

The Photos-style in-sheet JPEG/HEIF "Options" toggle is a **private** system
affordance for `PHAsset` — **not available to third-party apps**. The supported
equivalent is registering multiple representations on one `NSItemProvider` so the
receiving app auto-selects the format it supports. Today only EPUB is produced
(EPUB alone satisfies Apple Books / Kobo / reMarkable / Boox); a future PDF
representation would register alongside it on the same provider.

## Tests

`LunaTests/ArticleExportServiceTests.swift` — valid-zip EPUB bytes + sanitized
filename, item provider advertises `UTType.epub`, throws without content.
