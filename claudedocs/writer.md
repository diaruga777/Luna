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

## Simulator audit (2026-09-05)

Every flow was driven on an iPhone 17 Pro and an iPad Pro 13" simulator
(iOS 26.2) through `LunaWriterUITests`, a scripted XCUITest driver (below),
because neither `idb` nor the blitz MCP could reach the iOS 26 simulator's
HID port and the Mac's own display locked mid-session. What it found, and
what changed:

- **Typed text was black on the night background.** `LayoutAttributeStyler`
  replaced every attribute on a restyled line and wrote no colour, so TextKit
  drew its default black. The styler now writes `EditorTheme.ink` with the
  font and paragraph style; every other colour stays a rendering attribute.
- **Rendering attributes never reached the screen.** TextKit 2 clears a
  fragment's rendering attributes whenever it lays that fragment out again,
  and an edit invalidates the fragment it touched, so the composer's viewport
  pass landed on fragments about to be rebuilt: markup stayed ink-coloured,
  syntax colours, focus dim and annotation washes never showed.
  `RenderingAttributeComposer` now installs the layout manager's
  `renderingAttributesValidator` (chaining any UIKit installed first) and
  paints each fragment as it is laid out; `applyNow` still repaints the
  viewport for colour-only changes. `RenderingAttributeComposerTests` pins
  the validator; `MarkdownTextStorageTests` pins the ink.
- **Focus mode did nothing when switched on.** The lit range was computed
  only on a caret move. `EditorViewController.setFocusMode` recomputes it.
- **Settings had no button.** Only ⌘, and the Mac menu opened it. The
  sidebar carries a gear (`GroupsSelectionDelegate.groupsViewControllerRequestsSettings`).
- **The pushed sheets list had no back button** on a phone (its Edit item
  replaced it); `leftItemsSupplementBackButton` keeps both.
- **The @ overlay called every note "From another document"**:
  `SQLiteNoteIndex` built hits with no `documentIDs`. Hits now carry their
  sheets and text (`WriterNoteIndexTests`).
- **Filters were a dead end**: a library-wide filter was never listed, and
  no filter could be edited or deleted. `FilterEditorViewController` edits
  name, search text, favourites, modified-within and keywords; filter rows
  have Edit and Delete; library-wide filters sit at the root of Groups.
- Smaller: a long title squeezed the notes button out of the header; the ⋯
  menu's Statistics showed an alert while the counts bar showed the sheet;
  Delete sat mid-menu; Settings printed the raw container path as the storage
  location; the notes panel, the sheets list, the Trash and a search with no
  matches showed blank pages; the goal target was a borderless field on the
  night background; New Group landed as "New Group" with no name prompt; the
  Trash had no Empty action; iPad kept a dead back chevron beside a visible
  sheets column; "1 documents".

Verified working and left alone: New Document from the sidebar and the list,
heading/list/emphasis/code rendering, the notes panel save path and its
count badge, "@" lookup and note creation, snapshots on close, export to the
share sheet, Move, Keywords, Goal, group rename and context menus, Trash and
Restore, the two- and three-column iPad layouts with the side notes panel.
Read-along cannot run on a simulator (no TrueDepth camera, no on-device
speech model), so its chrome stays hidden there by design.

### Live Markdown (2026-09-07)

Markers hide by size, not colour. `LayoutAttributeStyler` gives every
marker run outside the reveal range a 0.1 pt font plus a per-character
kern that cancels that font's own width, so the run lays out zero points
wide and every character offset still maps one to one (the recipe is
ported from nodes-app/swift-markdown-engine, Apache 2.0 —
`THIRD_PARTY_NOTICES.md`). `.kern` applies to EVERY character, so the
kern is one character's share of the run width, never the whole width.

**What hides**: heading hashes with the space after them and any closing
run, blockquote `>` marks, an UNORDERED list item's `- ` and its
`[ ] `/`[x] ` box, a thematic break's `---`, and every inline marker
(`**`, `*`, `~~`, `==`, backticks, link and image brackets with their
destination, autolink angle brackets, a hard break's trailing spaces).

**What stays**: fence delimiters and fenced code (the backticks are the
code), an ordered item's `1.`, table pipes, a footnote definition's
`[^1]:` and a footnote reference — nothing paints in their place.

**What reveals**: the paragraphs the selection touches.
`MarkdownTextStorage.setRevealRange` widens a selection to whole
paragraphs, restyles only the paragraph the caret left and the one it
reached, and tells its observers those two ranges;
`EditorViewController.textViewDidChangeSelection` calls it. The reveal
lives on the storage, not on the styler, so `processEditing`'s rescan
restyles a line with the same reveal the caret last set and
`LayoutAttributeStyler` stays `Equatable` on metrics and font alone.
`MarkupLayer` greys only revealed markers; a collapsed one is invisible
and gets no colour.

**Where decorations are painted**: `WriterTextLayoutFragment`, an
`NSTextLayoutFragment` subclass installed through
`WriterLayoutFragmentProvider` on `WriterTextView`'s layout manager. It
paints a dot for a bullet, a `square`/`checkmark.square` for a task, one
`EditorTheme.quoteBar` bar per blockquote level, and a hairline rule for
a thematic break — all in the gutter the collapsed marker left, on the
text's own baseline, and suppressed on the revealed paragraph. A hidden
list item's paragraph style starts its first line at the wrapped lines'
indent, so the gutter exists; `EditorMetrics.collapsedLineHeight` floors
a line box whose every character collapsed.

A tap in a task item's gutter ticks its box. Two ordering facts shape
that gesture, both measured on iOS 26.2: a second tap recogniser on the
text view takes caret placement away even when it fails every touch (so
the gate returns true from `shouldRecognizeSimultaneouslyWith`), and the
text view's own tap reveals the line before any recogniser reaches its
action (so the hit is decided in `shouldReceive` at touch down and
remembered).

Verified on the simulator through the UI driver: typing `# Heading`,
`**bold** and *italic*`, `- item`, `- [ ] task`, `---` and `> quote`,
then tapping between lines. Markers collapse when the caret leaves and
come back at full size when it returns; the four decorations render; a
gutter tap turns `- [ ]` into `- [x]`.

### The UI driver

`LunaWriterUITests/WriterFlowUITests.swift` runs one test that reads a
`;`-separated script from `WRITER_UI_SCRIPT` and writes a numbered PNG per
`shot:` step to `WRITER_UI_SHOTS` (a host path — simulator processes share the
host filesystem), plus an accessibility dump per `dump:`. Commands: `shot`,
`dump`, `sleep`, `tap:<label>`, `tapType:<type>|<label>`, `tapIndex:<type>|<n>`,
`tapAt:x,y`, `pressAt`, `press:<label>`, `tapAlert:<label>`, `type:<text>`,
`typeInto:<label>|<text>`, `typeFirstField:<text>`, `swipeUp/Down/Left`,
`back`, `exists:<label>`, `rotate:landscape|portrait`, `background`. Pass the
two variables with the `TEST_RUNNER_` prefix as xcodebuild's environment:

```sh
TEST_RUNNER_WRITER_UI_SHOTS=/tmp/shots TEST_RUNNER_WRITER_UI_SCRIPT='tap:All Documents; shot:list' \
  xcodebuild test -scheme LunaWriter -destination "platform=iOS Simulator,id=$SIM" \
  -only-testing:LunaWriterUITests DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO
```

A sidebar section header is a cell with the same label as its row (`Trash`),
so tap rows by coordinate or `tapType:cell|…` with care. The test target is
a plain `PBXNativeTarget` hand-added to `project.pbxproj` (the `xcodeproj`
gem cannot save this project); the `LunaWriter` scheme lists it as its one
testable.

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
