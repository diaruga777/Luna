# Luna Writer

Luna Writer is a standalone Markdown writing app (`LunaWriter` target, bundle
`com.hsanabria.luna.writer`, URL scheme `lunawriter://`, strings suffix
`_Writer`). It shares no store with the other Luna apps and talks to no
server. The design and the decisions behind it are in
`claudedocs/plans/writer-app.md`; this page says what shipped and where.

## Shape

| Tier | Module | Holds |
| --- | --- | --- |
| models | `LunaWriterModels` | ids, `WriterDocument` (a sheet), `WriterGroup`, `WriterNote`, `Annotation`, `AuthorshipSpan`, `TextAnchor`, filters, goals |
| text | `LunaWriterText` | per-line Markdown scanner and the incremental `MarkdownDocumentModel`, sentence/word segmenters, part-of-speech tagging, statistics, `TextAnchorResolver`, title derivation, HTML renderer, editing commands |
| storage | `LunaWriterStorage` | `writer.sqlite` (FTS5 for notes and sheets, embeddings, marks, snapshots), the `.md` file layout with folder watcher and reconciler, the note index and router, settings, intent services |
| voice | `LunaWriterVoice` | on-device transcription (`SFSpeechRecognizer` on iOS 18, `SpeechAnalyzer` on iOS 26), energy VAD, utterance segmentation, gazeread's command classifier |
| gaze | `LunaGaze` | the ARKit tracker shared with the Reader's RSVP, plus filters, gate, affine calibration with pursuit sweeps, and the pure `ReadingTracker` |
| editor | `LunaWriterEditor` | TextKit 2 editor: layout attributes in `MarkdownTextStorage`, rendering attributes composed per viewport from ordered layers (markup, syntax, authorship, focus, annotation, reading), Focus mode, Authorship, the "@" mention overlay, `DocumentSession` |
| read-along | `LunaWriterReadAlong` | gaze + voice over an open sheet: coordinator, calibration screens, HUD, band/annotation layers |
| organiser | `LunaWriterLibraryUI` | triple-column split view: groups sidebar, sheets list, editor container; notes panel; keyword/goal/snapshot editors; export; settings |
| app | `LunaWriter/` | `WriterWiring` (composition root), the App Intents, deep links |

The organiser never imports the editor or read-along modules. It declares
seams (`DocumentEditing`, `DocumentEditorMaking`, `ReadAlongChromeProviding`,
`ReadAlongSettingsHandling`, `NoteRelevanceProviding`) and
`WriterWiring` adapts the real types to them (`WriterEditorScreen`,
`WriterEditorMaker`). That is what let three agents build the three UI tiers
in parallel, and it keeps the organiser testable with fakes.

## Where a sheet lives

Text is a plain `.md` file under `Documents/Library/<Group>/…/<Title>.md`,
visible in the Files app; renaming the title or moving the sheet renames the
file (`LibraryFileLayout`). Everything else about a sheet is a row in
`writer.sqlite` in Application Support. `LibraryFolderWatcher` +
`ExternalChangeReconciler` adopt files added, changed or deleted outside the
app: new file → new sheet in the mapped group, changed file → reload and
re-anchor marks, deleted file → trash. An open `DocumentSession` with unsaved
edits is left alone (`OpenSessionRegistry` answers `OpenDocumentQuerying`).

Anchors (`TextAnchor`) carry offsets plus the quoted text and 32 characters of
context, so annotations and notes survive edits and external rewrites;
`TextAnchorResolver` tries exact, nearby quote, unique quote, then fuzzy.

## Notes and "@"

Notes belong to sheets through `note_documents`; one note may sit on several.
`SQLiteNoteIndex` ranks with Pen's fusion (0.75 cosine over `NLEmbedding`
sentence vectors + 0.25 bm25 through a logistic), and prefix-matches the last
token for the "@" overlay. Typing `@` at a word boundary arms
`MentionController`; the query is the text after the marker; the overlay peeks
a note (never inserts it) or creates one from the query. `RelatedNotesRanker`
watches the 400 characters before the caret and feeds the related-note strip.

`AddWriterNoteIntent` files a note the way Pen's server does: an explicit
"new document:" prefix creates a sheet; otherwise every sheet scoring ≥ 0.45
gets the note; otherwise a new sheet titled from the first six words. Long
captures split into ≤ 10 sub-notes first (`NoteCaptureSplitter`).

## Authorship

`AuthorshipTracker` keeps a sorted span list: typed text is `.author`, a paste
is `.pasted`, "Paste as AI text" and the iOS 26 FoundationModels
continue/rewrite actions are `.ai(model:)`. The `AuthorshipLayer` tints
foreign spans; "Mark as mine" converts them. Spans are marks on the sheet and
persist with annotations through `DocumentMarksStoring`.

## Read-along

`ReadAlongCoordinator` runs the ARKit tracker → `GazeAffineCalibration` →
`OneEuroFilter` → `ReadingTracker` (gazeread's sentence-band model: Gaussian
likelihood per visible sentence with a transition prior, a reading-speed
word cursor, a 480 ms switch debounce). Speech onset snapshots the line being
read; the finished utterance becomes a coloured annotation (needs work /
expand / cut / keep) or a comment note anchored there. Calibration is a
pursuit sweep with a head-turn stage, four validation points and a grade in
degrees. Gaze needs a TrueDepth camera; voice needs an on-device speech model.

## Testing

Suites are `Writer*`, `Note*`, `Library*`, `Gaze*`, `Reading*`, `Voice*`,
`Utterance*`, `EnergyVAD*`, `Mention*`, `Authorship*`, `Rendering*`,
`Focus*`, `SentenceGeometry*`, `Groups*`, `Sheets*`, `EditorContainer*`,
`DocumentExporter*`, `DocumentNotesPanel*`, `ReadAlong*`, all in `LunaTests`
on the central host; `LunaWriter.xctestplan` / `LunaWriterTests` scheme
select them. The simulator ships no lexical-class model, so syntax colouring
tests assert the gate, not the colours. The `LunaGaze` product must stay
linked by the central Luna app: with only the test bundle linking it, Xcode
folded it statically into both the Reader framework and `LunaTests`, and the
RSVP suites' `supportOverride` landed in a copy the Reader never read.
