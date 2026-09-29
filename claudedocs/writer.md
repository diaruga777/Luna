# Luna Writer

## Library navigation refinement (September 30, 2026)

The library uses native grouped destinations on iPhone and an outline sidebar
on wider layouts. The root has a large Library title, document/note counts,
separate book and collection rows, and direct compose access. Redundant Library
and Trash section headings are removed. Counts follow create, move, trash, and
restore operations without rebuilding the sidebar for ordinary text autosaves.

Document, chapter, and note lists share an inset grouped presentation and a
visible search field. Document previews use a title, two-line excerpt, and a
quieter date/location line; accessibility text sizes can expand the title and
excerpt. Chapter numbers use simple inset badges. The compose button is always
in the same position. The More menu contains selection, sorting, book contents,
and Empty Trash as appropriate. Empty lists explain their state and offer a
contextual New Document, New Chapter, or New Note action.

Selection mode keeps native back navigation, disables actions until documents
are selected, reports the selection count, and offers Restore in Trash. Leaving
the list or changing scope clears selection mode and its toolbar. The library
clears its destination highlight on iPhone while retaining it beside visible
content on iPad. Move and document pickers use the same grouped styling.
The writing surface is unchanged.

Validation: the navigation/storage-focused unit suites and Simulator UI driver
cover library, documents, books/contents, notes, search, selection, and Trash.

## Books and notes navigation (September 2026)

Writer now centers on books, chapter collections, documents, and notes.
The sidebar offers All Documents, All Notes, Last 7 Days, Books & Collections,
and Trash. Inbox and Favorites are no longer navigation destinations; saved
sessions on either reopen All Documents. Existing documents, notes, and legacy
metadata remain in the library. The internal inbox group is still the storage
location for unfiled documents and is labeled Unfiled Documents in move pickers.

- **All Notes** includes attached and standalone notes exactly once, ordered by
  update date, with full-text search. Rows wrap the entire note and show linked
  document titles. Tap to edit in a scrollable sheet; the link menu opens linked
  documents or attaches the note elsewhere. New notes can be captured here
  without creating a document. Long-press a row to delete it.
- **Books** can be created directly from the sidebar + menu. Each book uses the
  existing project group model and opens in manual chapter order. New Chapter
  creates a heading-backed document. Contents provides a table of contents,
  nested chapter collections, adding existing documents, and native Edit-mode
  reorder handles that also move chapters between collections. Collections
  retain their manual order in the sidebar and table of contents.
- **The editor** uses a standard navigation bar and native back navigation,
  with Chapters, Document Notes, and More controls. Navigation stays available
  while typing. Chapters opens the containing book, including its collections;
  an unfiled document can become a book. More offers a new following chapter,
  previous/next chapter navigation, and a stable `lunawriter://document/<uuid>`
  link for sharing references across chapters. Export, move, and delete remain.
- **The command palette** uses the full note text rather than the short FTS
  excerpt, wraps it in rows up to 520 points wide, and scrolls within the space
  above the keyboard. The exact Return target gets an explicit tinted fill,
  border, return glyph, and selected accessibility trait. Arrow-key changes and
  cleared selection update all four together. Note peek cards scroll long text;
  document notes use uncapped wrapping, and the related-note strip shows three
  lines with access to the full note panel.
- Goals, statistics, keywords, favorites, snapshots, read-along, and gaze
  tracking are removed from the editor/library controls and settings. Production
  wiring no longer creates read-along or gaze services or records editing-session
  snapshots. Their legacy storage types remain readable for compatibility.

The sections below document earlier implementation history; descriptions of the
removed controls and custom editor header are superseded by this section.


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
| editor | `LunaWriterEditor` | TextKit 2 editor: layout attributes in `MarkdownTextStorage`, rendering attributes composed per viewport from ordered layers (markup, syntax, authorship, focus, annotation, reading), Focus mode, Authorship, the command palette, `DocumentSession` |
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

## Notes and the command palette

Notes belong to sheets through `note_documents`; one note may sit on several.
`SQLiteNoteIndex` ranks with Pen's fusion (0.75 cosine over `NLEmbedding`
sentence vectors + 0.25 bm25 through a logistic), and prefix-matches the last
token for the palette. `RelatedNotesRanker` watches the 400 characters before
the caret and feeds the related-note strip.

The palette (`CommandPaletteController` + `CommandPaletteOverlayView`, in
`LunaWriterEditor/CommandPalette/`) is one inline surface for notes and
commands. **Trigger** is a setting, `WriterSettings.paletteTrigger`
(Settings → Editor → Command Palette): the default `.doubleSpace` opens on two
spaces typed within `CommandPaletteController.doubleSpaceInterval` (0.3 s) —
the second space is swallowed, the palette anchors after the first, and iOS's
own ". " shortcut for the same double space is refused; a slower pair is a
sentence's double space and stays text. `.atSign` opens on an "@" typed at a
word boundary and keeps the "@" as a visible marker (`markerLength` 1 vs 0).
Either way the query is typed straight into the sheet after the marker, six
words at most, on one line. Backspace on an empty palette closes it and
deletes nothing. **Return** runs the highlighted row: the first row is
highlighted (tinted, with a ↩ at its trailing edge) only when its match
scores at least `CommandPaletteController.returnThreshold` (0.8 — a word or a
prefix, "emd" → Em Dash; scattered subsequences stay unhighlighted), or
when words typed match nothing but the New note row (Q5's "Return with no
match creates a note"). The arrows or a tap pin another row for the same
query. With nothing highlighted Return types a newline and closes the palette.
An empty or whitespace-only query has no result controls or heading. A native
Liquid Glass outline surrounds the real insertion caret and expands behind the
query's live glyphs (`PaletteQueryDecoration`). Wrapped input gets one glass
segment per visual line; the decoration never changes document attributes,
steals touches, or substitutes its own text input. It follows scroll and layout
changes and disappears when the session ends or a note peek opens.
The panel keeps its screen origin for the entire palette session, including
soft line wrapping, typewriter scrolling, and pending searches. Only a new
session or a changed keyboard/viewport resets placement. Results scroll within
available space rather than flipping above/below the query as their count changes.
When the panel is below the initial line, the sheet scrolls enough to keep a
wrapped query’s insertion point above it.
Changing the query clears old results and their Return action while the next
search is pending.

Every nonempty query searches **all domains**, with no command prefixes or
exclusive modes: `epsilon` finds ε directly; `happy` finds related words as
well as any matching notes and symbols. Results are merged by descending
match score, with stable ties, into six result rows. Symbols occupy a single
horizontal strip at the strongest symbol's position, ordered best-first; each
tile displays only the character, with its name available to VoiceOver. The
strip counts as one row, leaving room for notes and words. Other results use
one concise title with no explanatory subtitle. Each result is a native glass
button, grouped in a `UIGlassContainerEffect`, with consistent 48-point minimum
hit targets, quiet SF Symbols, and a Return indicator on the selected result.
Results enter with a short, damped movement; Reduce Motion suppresses it. Keyboard selection follows
the visible order and highlights the actual symbol tile or result; local notes only take precedence over other
notes on a tie. Note text also uses the same lexical matcher as symbol names
and commands. The New note action stays last for nonempty queries.
Formatting commands and their Markdown insertion helpers have been removed.

| Domain | Source | Row action |
| --- | --- | --- |
| Symbols (`epsilon`, `emdash`, …) | `SymbolCatalog` (LunaWriterText): fixed Unicode ranges and a hand alias table, ranked with `FuzzyMatcher` | insert the character |
| Related words (`happy`, …) | `WordThesaurus`; `EmbeddingThesaurus` uses on-device English word neighbours and their cosine similarity, capped below direct word/prefix matches (0.79). Inflections are dropped and case is preserved. An unavailable lookup contributes no rows | insert the chosen word |
| Notes | FTS note search across the current sheet and library, merged without duplicates | peek at the note; closing removes the query |
| `new chapter` | `ChapterOrganizing` seam (`EditorEnvironment.chapters`); `ChapterOrganizer` (LunaWriterStorage) | cut the text after the caret into the next chapter's sheet |

**Chapters.** A project is a `WriterGroup` of kind `.project` (icon
`book.closed`); its sheets are the chapters, in manual order. The first "new
chapter" on a plain sheet creates the project — named after the sheet, inside
the sheet's folder or at the top level for an Inbox sheet — and moves the
sheet in as chapter one; every later one inserts a sheet right after the
current chapter. The editor cuts everything after the caret, saves, and hands
the text over; the new sheet gets a `# Chapter N` heading unless the moved text
opens with a heading of its own. The new sheet then opens through
`EditorViewControllerDelegate.editor(_:didStartChapter:)` →
`DocumentEditingDelegate.editor(_:requestsOpening:)` →
`EditorContainerViewController.documentOpener` (`DocumentOpening`, the root).
`WriterGroup.Kind.isEditable` is what the sidebar, the group SQL and the
renumbering treat as "a folder the writer owns"; an older build reads the
unknown raw value as `.user`.

Project lists open in manual chapter order. Their inset rows show a glass
number badge, title, one-line excerpt and word count; dates and keyword chips
stay in the ordinary document list. Numbers follow the full project's manual
order, including while searching or viewing an alternative sort. Reordering
updates those numbers with native list animations (respecting Reduce Motion).
Leaving a project restores the ordinary list's previous sort. The existing
search, sort, drag, swipe, move, and multi-select actions remain available.

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
show a red note above the keyboard and retry. The registry's dirty snapshot
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
keeps the editor above the keyboard, replacing the custom
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
count badge, the palette's note lookup and creation, snapshots on close, export to the
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
and gets no colour. A revealed list item or quote hangs its marker in the
gutter — `LayoutAttributeStyler.paragraphStyle(for:hidingMarkers:
revealedMarkerWidth:)` pulls the first line back by the marker's width —
so revealing a line never moves its words.

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
`back`, `exists:<label>`, `rotate:landscape|portrait`, `background`,
`relaunch` (home, kill, cold launch — a force quit). Pass the
two variables with the `TEST_RUNNER_` prefix as xcodebuild's environment:

```sh
TEST_RUNNER_WRITER_UI_SHOTS=/tmp/shots TEST_RUNNER_WRITER_UI_SCRIPT='tap:All Documents; shot:list' \
  xcodebuild test -scheme LunaWriter -destination "platform=iOS Simulator,id=$SIM" \
  -testPlan LunaWriterUI DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO
```

A sidebar section header is a cell with the same label as its row (`Trash`),
so tap rows by coordinate or `tapType:cell|…` with care. The driver is the one
target in `LunaWriterUI.xctestplan`, the second plan on the `LunaWriter`
scheme's Test action, so a plain `xcodebuild test -scheme LunaWriter` runs the
unit bundle and never the driver.

## Reopening the last page (2026-09-07)

Luna Writer comes back to the page it was on. `WriterSessionState`
(`LunaWriterStorage`) holds four values in the same defaults suite
`WriterSettings` uses — the open sheet, the sidebar scope, the caret's
location and whether the keyboard was up. The scope is stored as
`LibrarySelectionValue`, a mirror of the organiser's own `LibrarySelection`,
because that type belongs to `LunaWriterLibraryUI` and this tier holds no
view types.

`LibraryRootViewController.restoreLastSession()` runs once, from
`viewDidAppear`: that is the first moment `isCollapsed` says which columns
exist, and setting a navigation stack from inside a layout pass loops
UIKit's layout until the process runs out of memory (measured at 1.9 GB).
It sets the whole page at once and never animates — a collapsed stack
becomes groups/sheets/editor, an expanded root takes the secondary column.
A sheet that is gone or trashed restores the scope alone; a sheet opened
before the root appeared (a deep link, an intent) is already the page, so
the restore stands down. On a first run `WriterWiring` seeds the snapshot
with the Welcome sheet `bootstrap()` returns, so it opens through the same
path.

The page is recorded as the writer moves: `show(document:)`,
`documentDidClose`, each sidebar selection, and each editing-state report.
`WriterWiring.applicationDidEnterBackground` writes the whole snapshot as
well, which is what catches a caret the autosave has not reached — and,
because a popped editor has already deallocated, what forgets a sheet the
writer backed out of.

The caret crosses two seams. `DocumentEditing.editingState` /
`restoreEditingState(_:)` and `DocumentEditingDelegate.editor(_:
didChangeEditingState:)` are the organiser's side;
`EditorViewControllerDelegate.editorDidChangeEditingState` is the editor's,
with `WriterEditorScreen` between them. The editor reports when editing
begins and ends and on each autosave — the caret's resting position, never
per keystroke — and puts a restored caret back clamped to the text it
finds, since the file may have been rewritten elsewhere meanwhile. The
keyboard waits for `viewDidAppear`, and comes up only when it was up; a
sheet with nothing in it still takes it, as before.

Beside a visible editor column the sheets list keeps the open sheet
highlighted (`SheetsViewController.openDocumentID`), reselected after each
diffable apply. A collapsed list is about to be pushed off screen, so a tap
there still flashes and clears.

## Minimal chrome (2026-09-07)

The header hides while the writer types, and comes back at the top of the
page or on a double tap. `DocumentEditingDelegate.editor(_:wantsChromeHidden:)`
and `editorDidRequestChromeToggle(_:)` carry the cue from `EditorViewController`
(mirrored on `EditorViewControllerDelegate`, forwarded by `WriterEditorScreen`)
to `EditorContainerViewController.setChromeHidden(_:animated:)`. The editor
fires the cue from `textViewDidBeginEditing`/`textViewDidEndEditing` (focus
hides, losing it shows), from `scrollViewDidScroll` on arrival at the top
(`contentOffset.y <= -adjustedContentInset.top + 1`, fired once per arrival
rather than every frame spent there, and only while the scroll view is
tracking, dragging or decelerating — the keyboard rising and a caret
restore move the offset through the top too, and neither is a request to
see the header), and from a two-tap
`UITapGestureRecognizer` on the text view that only claims a touch on blank
space — `EditorViewController.isBlankSpace(at:)` asks
`NSTextLayoutManager.textLayoutFragment(for:)` for the fragment under the
point and treats it as text only when `closestPosition(to:)` resolves inside
that fragment's own range, so a double tap on a word still runs the system's
word-selection gesture untouched (`gestureRecognizer(_:shouldReceive:)` gates
it, not `require(toFail:)`, so a single tap stays instant).

`setChromeHidden` swaps the editor's top constraint between the header's
bottom anchor and the view's own top anchor (the text view's own
`contentInsetAdjustmentBehavior` still clears the safe area), re-anchors the
read-along chip and a side notes panel the same way, and slides the header up
by its own height while fading it — 0.25 s ease-in-out, alongside
`layoutIfNeeded`. Toggling while the keyboard is up shows the header until
the next keyboard event, because the state machine has no separate "pinned"
flag: a toggle just flips `isChromeHidden`, and the next focus/blur cue sets
it again unconditionally.

## Testing

The Writer suites are `LunaWriterTests/` (58 files, 600 tests), a unit-test
bundle hosted on the `LunaWriter` app and run from that scheme's default test
plan (`LunaWriter.xctestplan`):

```sh
xcodebuild test -scheme LunaWriter -destination "platform=iOS Simulator,id=$SIM" \
  DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO
```

`scripts/add_writer_tests_target.rb` owns the bundle's topology. It links the
same ten static products the app links, so a suite reaches
`LunaWriterText`/`Storage`/`Voice`/`Editor`/`ReadAlong`/`LibraryUI` while the
central `Luna.app` links none of them. The suites are `Writer*`, `Note*`,
`Library*`, `Voice*`, `Utterance*`, `EnergyVAD*`, `CommandPalette*`, `FuzzyMatcher*`,
`SymbolCatalog*`, `MarkdownFormatStyle*`, `WordThesaurus*`, `ChapterOrganizer*`, `Rendering*`,
`Focus*`, `SentenceGeometry*`, `SentenceEmbedding*`, `Groups*`, `Sheets*`,
`Snapshots*`, `Editor*`, `LineTable*`, `MarkdownTextStorage*`, `LRUCache*`,
`SyntaxColourLayer*`, `Speech*`, `GoalProgress*`, `SessionTrace*`, `MacSeam*`,
`ExternalChangeReconciler*`, `GazeCalibrationFlow*`, `DocumentExporter*`,
`DocumentNotesPanel*` and `ReadAlong*`.

`LunaWriterModels`-only suites stay in `LunaTests`: `AuthorshipSpanList*`,
`WriterModelsCodable*` and the `Gaze*` / `Reading*` eye-tracking suites, which
exercise `LunaGaze` as the central app's Reader uses it. The `LunaGaze` product
must stay linked by the central Luna app: with only the test bundle linking it,
Xcode folded it statically into both the Reader framework and `LunaTests`, and
the RSVP suites' `supportOverride` landed in a copy the Reader never read.

The simulator ships no lexical-class model, so syntax colouring tests assert
the gate, not the colours.

## Surface tweaks (2026-09-07, evening)

The Markdown accessory bar and the word-count bar are gone: the editor is
text, a keyboard, and nothing between them. Statistics stay one tap away in
the ⋯ menu (`StatisticsSheet`, worded by `StatisticsFormatting`); a failed
save shows a red note above the keyboard until the retry lands. The
related-note strip is the only input accessory, and only while a match
exists. `autocorrectionType` is `.no`, which also removes the predictive
row, so the keyboard stands at its own height. An empty sheet seeds the
text view's typing attributes from the styler's body attributes, so the
caret is body-sized before the first keystroke. The read-along chip hides
with the header. When the app returns to the foreground with the keyboard
recorded as up, `LibraryRootViewController.refocusEditorIfNeeded()` raises
it again at once (`WriterSceneDelegate.sceneWillEnterForeground`, and again
in `sceneDidBecomeActive` as a fallback). The keyboard state is captured the
instant the scene resigns active and recording is suspended until it is
active again: the system takes the keyboard down on the way to the app
switcher, and a force quit follows with no further hook. **Before the first
frame**: the page is restored in the root's `viewWillAppear` and the editor
asks for the keyboard in its own `viewWillAppear`, so the keyboard is drawn
with the first frame instead of sliding up after it (`viewDidAppear` stays
as the fallback for a view that had no window yet). iOS offers no way to
disable the keyboard's own slide; requesting focus before the first render
is what makes it instant.

## App icon

Writer uses the Luna family's moon background and curved Liquid Glass composition,
with a rose tint and a fountain-pen nib. The editable source is
`Design/IconComposer/Luna Writer.icon`; the app master is
`Luna/Assets.xcassets/AppIconWriter.appiconset/AppIconWriter-1024.png`. The
96/192/288-pixel `LunaAppIconWriter` resources show the same artwork in every
Luna app. Export instructions are in `Design/IconComposer/README.md`. The old
placeholder generator has been retired.
