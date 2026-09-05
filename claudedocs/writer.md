# Luna Writer

Luna Writer is a standalone Markdown writing app (`LunaWriter` target, bundle
`com.hsanabria.luna.writer`, URL scheme `lunawriter://`, strings suffix
`_Writer`). It shares no store with the other Luna apps and talks to no
server. The design and the decisions behind it are in
`claudedocs/plans/writer-app.md`; this page says what shipped and where.

**Wording.** The code, the tables and this page say *sheet*; every
user-visible string says *document* ("All Documents", "New Document", the
intents' "Document" parameter). Keep new strings on the user's word.

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
`ReadAlongSettingsHandling`) and
`WriterWiring` adapts the real types to them (`WriterEditorScreen`,
`WriterEditorMaker`). The app adapter also observes library changes and refreshes an idle editor
when the reconciler publishes a newer file revision.

## Where a sheet lives

Text is a plain `.md` file under `Documents/Library/<Group>/…/<Title>.md`,
visible in the Files app; renaming the title or moving the sheet renames the
file (`LibraryFileLayout`). Everything else about a sheet is a row in
`writer.sqlite` in Application Support. `LibraryFolderWatcher` +
`ExternalChangeReconciler` adopt files added, changed or deleted outside the
app: new file → new sheet in the mapped group, changed file → reload and
re-anchor marks, deleted file → trash. An open `DocumentSession` with unsaved
edits is left alone (`OpenSessionRegistry` answers `OpenDocumentQuerying`).

Trashing a sheet moves its file into a hidden `.Trash/` folder under the
library root (excluded from the scan); restoring moves it back through
`LibraryFileLayout.path`, emptying the Trash unlinks, and deleting a group
moves its subtree's files there first. A file that comes back after being
missing restores its trashed row instead of being adopted as a new sheet.
The watcher holds one dispatch source per directory and rescans on
foreground. Paths are compared NFC-normalised.

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

## Hardening (2026-09)

`claudedocs/plans/writer-hardening.md` records the full-app review, its six
reports and what landed. Highlights a maintainer should know: the scene
delegate flushes open sessions on background (the app-delegate hook is never
called under the scene lifecycle); `LibraryRootViewController` shows three
columns only when the width holds two side columns plus a ≥ 560 pt editor;
sheets-list swipe actions come from the list configuration's providers and
sheets have a context menu; Settings opens from the sidebar gear or ⌘,; every
action sheet became a `UIMenu` so iPad never presents an unanchored popover;
`MarkdownTextStorage` applies the model edit inside `replaceCharacters`;
`DocumentSession.save()` is asynchronous with a revision guard and
`saveNow()` for flushes; `SentenceLayout`/`WordLayout` and
`AuthorshipSpanList` live in `LunaWriterModels`, and `LunaGaze`'s ARKit half
is behind `#if canImport(ARKit)` so the editor tier no longer depends on
ARKit. Read-along marks go through `ReadAlongTextHosting` into the open
`DocumentSession` (never into the marks row directly), every session is torn
down when its sheet closes, and the coordinator is told about relayout,
text changes and user scrolls through the editor's `EditorLayoutObserving`.
The tracker and display geometry are handed in by `WriterWiring`, so the
read-along module names neither ARKit nor `UIScreen.main`, and the app
compiles for the Mac's "Designed for iPad" variant.

### Compact width (2026-09-04)

On an iPhone the split view is collapsed, so the sheets column's view is
not loaded until it is pushed. `SheetsViewController.reload()` returns
until `viewDidLoad`, which applies the selection it kept; the first
sidebar tap used to trap on the nil data source. Because the sidebar is
the only column with a `+` there, its menu and each group's context menu
lead with **New Document**, routed through
`GroupsSelectionDelegate.groupsViewController(_:requestsNewDocumentIn:)`
to `SheetsViewController.createSheet(in:)`. Read-along's tap recogniser
on the text view takes a touch only when a mark is under it
(`UIGestureRecognizerDelegate` on the wiring's `Session`); before that it
competed with the text view's own tap and the keyboard never came up.
The HUD menu's calibration items are "Calibrate gaze (25s)" and
"Recalibrate gaze (8s)" — the old "Quick touch-up" read as text
correction.

## Writing and note capture review (2026-09-05)

Character mutations in `MarkdownTextStorage` drive session dirtiness and mark
shifting directly. UITextView's selection/delegate ordering is not used to
infer edits. This covers typing, paste, undo and marked-text replacement.
Autosave uses one private common-run-loop timer; the injectable autosave
scheduler and its two protocols were removed. A queued save stays dirty until
its write succeeds. A synchronous flush consumes an already-completed queued
write even if the main-queue callback has not run. Failures retain the buffer,
show a message in the statistics bar and retry. The registry's dirty snapshot
updates on state changes, with no polling timer.

Text saves fetch the current path and update only text-derived database
columns. They preserve favourites, keywords and goals, serialise writes to the
file store, remove the old path after updating the row, and index once using
the text already in memory. The reconciler defers missing files for dirty
open documents. `WriterEditorScreen` now connects real library notifications
to `DocumentSession.refreshDocument`; an asynchronous reload checks again for
local edits before replacing the buffer. New empty documents focus the editor.

The notes panel has a multiline composer and an explicit Save button. Writes
run on a serial background queue; success clears the composer, failure keeps
the draft and shows a retry message. Done saves a pending draft before closing,
and a draft prevents interactive dismissal. Tap an ordinary note to edit it;
anchored notes still jump to the document and have an Edit note context action.
The note repository owns attachments and indexing, so the panel no longer
repeats those operations or takes a separate index dependency. A failure in
the derived embedding cache cannot turn a committed note into a reported
failure. The unused `NoteRelevanceProviding` interface and its test-only
implementation were removed; the panel orders notes by recency.

Editor delegate updates no longer rebuild header controls or query notes per
keystroke. Related-note requests are invalidated when their context becomes
empty, and Focus mode avoids paragraph work when switched off. Markdown model
recovery behaves the same under XCTest and in the actual app.

Formatting composition uses Foundation attributed strings instead of scanning
every contribution at every boundary. Painting is restricted to the viewport
and slack, including after large edits, and refreshes while scrolling. The
1,000-paragraph Debug simulator composition benchmark fell from 1.939 seconds
to 0.011 seconds; this measures composition rather than whole-app latency.

AI continue/rewrite apply the complete model response as one attributed edit
after checking cancellation and intervening edits. The simulated typing timer
was removed; a rewrite is one undo operation. UIKit's keyboard layout guide
keeps the editor and statistics bar above the keyboard, replacing the custom
keyboard observer, injectable metrics and unused Mac stub.

See `claudedocs/writer-review-2026-09-05.md` for findings, verification and limits.

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
