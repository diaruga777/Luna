# Luna Writer — plan

Status: LANDED 2026-09-03 — every work package merged; what shipped is described in `claudedocs/writer.md`. Full suite on a fresh simulator: 4594 tests, 22 skipped, 8 failures, all eight in the pre-existing set documented before this work (see `known-test-failures` memory). Standalone fifth-and-a-half Luna app.
Nothing here talks to the other Luna apps or to any backend.

Luna Writer is a Markdown writing app for iPhone and iPad. It borrows from
four sources. Each borrowed idea is named here with what it becomes in Swift.

| Source | Borrowed | Becomes |
| --- | --- | --- |
| iA Writer | clean surface, Markdown styling, Focus mode, syntax (part-of-speech) colouring, Authorship (pasted / AI text shown apart) | `LunaWriterEditor` + `LunaWriterText` |
| Ulysses | library → nested groups → sheets, Inbox, Favorites, filters, keywords, goals, trash | `LunaWriterLibraryUI` + `LunaWriterStorage` |
| Pen (`~/Desktop/puttyos/ios/Pen`) | notes attached to a document, "@" capture, hybrid FTS + embedding relevance, `SendNoteIntent` | `NoteIndex`, `MentionController`, `AddWriterNoteIntent` |
| gazeread (`~/Desktop/puttyos/sites/gazeread`) | sentence-band gaze reading tracker, calibration, speak-while-reading → colour highlight or comment | `LunaGaze` (extended) + `LunaWriterVoice` + `LunaWriterReadAlong` |

Out of scope for v1: any sync, any server, spell / grammar / style checks,
Ulysses glue/split sheets, external folders on other providers, Mac.

## 0. What the two local references actually do (measured)

**Pen has no on-device index.** `PenDocStore` is a JSON read cache. FTS5,
`text-embedding-3-small` vectors, and the fusion score
(`0.75 × cosine + 0.25 × bm25`, cosine rescaled from the [0.10, 0.50] band)
all live in `sites/pen/lib/index.js`. Pen's "@" (`AtNoteCapture`) is a
floating card that CREATES a note from what you type after "@"; the "@" is
swallowed, the note lands in the doc's tray, nothing is inserted in the text.
Pen's continuous relevance (`NoteMatcher`: 400-char trailing window before
the caret, 500 ms debounce, top-3 "straighten") is a separate mechanism.
`SendNoteIntent` posts to `/_note` headless; the server auto-routes the note
into a document by the same retrieval. Pen uses `UITextView(usingTextLayoutManager: true)`
and HTML, not Markdown.

We port the *ideas* to local code: FTS5 on the system SQLite, sentence
embeddings from `NLEmbedding` (on-device, no key), the same fusion
formula, the same trailing-window matcher, and a "@" that is BOTH a lookup
and a capture.

**gazeread does not trust gaze to a word.** MediaPipe iris landmarks → per-eye
ridge regression → One-Euro filter → I-DT fixation filter → a probabilistic
sentence tracker (`Reader`): Gaussian likelihood per visible sentence
(σy = 100 px ≈ 2°, σx = 420 px) × a transition prior, 480 ms switch debounce,
and a reading-speed model (230 wpm, bounded 120–520) that advances the word
cursor inside the active sentence, nudged by horizontal gaze and hard-snapped
after a 400 ms dwell far from the model. Voice: Silero VAD → Moonshine ASR
(on-device) → `classify()` lexicon (purple "needs work", blue "expand", red
"cut", green "keep", else comment) → annotation anchored to the line being
read at **speech onset**, stored as `{sentenceIndex, wordStart, wordEnd}`.
Calibration: 3-row pursuit sweep, head-turn stage, lag search over
60–260 ms, 4-point validation, grades Good < 80 px / Usable < 150 px.

On iOS the raw signal is ARKit `lookAtPoint` (TrueDepth), which Luna Reader
already wraps (`GazeTracker.swift`, `GazeCalibration.swift`,
`GazeScreenProjection.swift` in LunaReaderUI). ARKit is metric and far less
noisy than a webcam, so the regression shrinks to a 2-D affine correction
with a bias, fitted by the same pursuit sweep. The sentence tracker, the
fixation filter, the anchor-at-onset rule and the classifier port directly.

## 1. Decisions taken, and open questions

Answered 2026-09-03. Q1 Luna Writer, Q2 Luna night/predawn, Q3 files + SQLite, Q4 Pen routing, Q5 peek only, Q6 paste + FoundationModels. The rows keep the chosen answer.

| # | Question | Default | Why it matters |
| --- | --- | --- | --- |
| Q1 | App name | **Luna Writer**, target `LunaWriter`, bundle `com.hsanabria.luna.writer`, scheme `lunawriter://` | Folder, module prefix, strings suffix `_Writer` |
| Q2 | Look | Luna night/predawn chrome (LunaDesignSystem, pinned dark), editor palette = ink on the Luna sky, iA-blue caret and accent | The alternative (iA paper: light + dark following the system) means NOT pinning `userInterfaceStyle` and a separate palette |
| Q3 | Where document text lives | **Plain `.md` files** under `Documents/Library/<Group>/…/<Title>.md`, visible in Files, reconciled on external edits; metadata, notes, annotations, authorship in `writer.sqlite` | SQLite-only is simpler (no file layout, no watcher) but invisible to Files and to other editors |
| Q4 | Notes added by the App Intent with no document | **Pen's deterministic router**: an explicit "new document: …" prefix creates a sheet with that title; else the note attaches to EVERY candidate sheet whose fused score ≥ 0.45; else a NEW sheet titled from the note's first six words (title-cased) is created in the Inbox and the note attached. Captures over 500 chars split into ≤ 10 sub-notes first. | A note may therefore belong to several sheets (`note_documents` join) |
| Q5 | What picking a note in the "@" overlay does | **Peek only, never insert.** Return or tap opens the note in a peek card over the text; the last row (or Return with no match) **creates a new note** from the query (Pen). Nothing from a note is ever copied into the sheet by the overlay. | Removes the `.note` authorship source and the insert action |
| Q6 | How AI text enters | Authorship tracks **paste** (`.pasted`) and a **"Paste as AI text"** edit-menu item; iOS 26 devices also get on-device **"Continue writing" / "Rewrite selection"** (FoundationModels) producing `.ai` spans | Dropping FoundationModels removes `AIWritingAssistant` |
| Q7 | Voice comment → note | A spoken non-command utterance becomes a **note anchored to the range** plus a `.comment` annotation | Keeps one note model for typed, "@", intent and voice |
| Q8 | Preview | **No live preview**; export to Markdown / HTML / PDF / plain text | A preview pane adds an HTML renderer view |
| Q9 | Ulysses scope | nested groups, sheets, Inbox, Favorites, filters, keywords, goals, trash, manual sort, version snapshots | glue / split / merge deferred |
| Q10 | Gaze hardware | **TrueDepth only** (as Luna Reader); no gaze UI on other devices; voice works everywhere | Front-camera Vision-based gaze is a research project |

Assumptions not worth a question: iPhone + iPad (`TARGETED_DEVICE_FAMILY 1,2`),
iOS 18 deployment with iOS 26 gates, Swift 5 mode, tests in `LunaTests`
under a `LunaWriter.xctestplan` (the Vault pattern), no App Group needed,
placeholder icon generated by script, `spellCheckingType = .no` and
`inlinePredictionType = .no` (autocorrect and smart punctuation stay on the
system setting), English `NLTagger`/`NLEmbedding` models with graceful
no-op when a language is unsupported.

## 2. Targets and modules

New SwiftPM targets in `LunaLibraries/Package.swift` (Foundation-only where
marked F; UIKit where marked U):

```
LunaWriterModels      F   ids, value types, TextAnchor, enums            deps: —
LunaWriterText        F   Markdown scanner, segmenters, POS, stats,       deps: LunaWriterModels
                          anchor resolver, HTML renderer, title deriver
LunaWriterStorage     F   writer.sqlite, repositories, file layout +      deps: LunaWriterModels, LunaWriterText
                          watcher, NoteIndex (FTS5 + NLEmbedding),
                          NoteRouter, settings, intent services
LunaWriterVoice       F   speech capture, transcriber, VAD, classifier    deps: LunaWriterModels
LunaGaze              U   EXTRACTED from LunaReaderUI + new: One-Euro,   deps: —  (LunaReaderUI gains
                          fixation filter, affine calibration, pursuit           dependency and
                          path, ReadingTracker (pure)                           `@_exported import LunaGaze`)
LunaWriterEditor      U   TextKit 2 editor, style layers, focus,          deps: Models, Text, Storage,
                          authorship, "@" mention, document session,           LunaDesignSystem
                          sentence/word geometry provider
LunaWriterReadAlong   U   calibration screens, ReadAlongCoordinator,      deps: Editor, LunaGaze, Voice,
                          HUD, reading + annotation overlays                    Storage, LunaDesignSystem
LunaWriterLibraryUI   U   Ulysses organiser, notes panel, settings,       deps: Editor, ReadAlong, Storage,
                          export, root split view                               LunaDesignSystem
```

App target `LunaWriter` (folder `LunaWriter/`): `WriterAppDelegate`,
`WriterSceneDelegate`, `WriterWiring` (composition root), `Intents/`,
`Info.plist`, `LunaWriter.entitlements`, launch screen. It links the eight
modules above plus `LunaDesignSystem`, `LunaModels`, `LunaAppConfig`
(design-system transitive). `LunaTests` links the same set so the suite
runs on the central host as today.

Project plumbing (hand-edited `project.pbxproj`, the gem crashes on this
project — see memory `luna-vault-tailscale-embedded`): native target,
`LunaWriter.xcscheme`, membership in `AllLunaApps`, `LunaWriter.xctestplan`
+ `LunaWriterTests.xcscheme`, `Verify bundled strings table` phase
(`scripts/add_strings_check_phase.rb`), strings copy
(`scripts/add_strings_to_app_bundles.rb`), `scripts/hide_generated_schemes.rb`,
`select_changed_tests.py` path rows, `strings_sync.py` intent scan path
`LunaWriter/Intents/`, `AppIconWriter` appiconset.

Shared-code edits: `LunaApp` gains `case writer` (detect `.writer`,
`storageIdentifier "writer"`, display name key) and `L10n` gains the
`_Writer` suffix; `BundledShortcut.displayName` gains the case (no
shortcut ships). `LunaLayout`, `LunaColors`, `NavHeaderBar`, `GlassStyle`,
`LunaShareSheet`, `AppearanceSettings` are reused as-is.

Standing rules that apply (from `CLAUDE.md`): protocol witnesses, never
stored closures, for every seam; ASD-STE100 comments only where code cannot
speak; every string through `L10n.string("Key")` with a `_Luna` fallback
and a `_Writer` override where wording differs; intent metadata as literal
`…_Luna` keys; tests assert behaviour.

## 3. `LunaWriterModels`

```swift
public struct DocumentID: Hashable, Codable, Sendable { public let rawValue: UUID; public init(_ = UUID()) }
public struct GroupID, NoteID, AnnotationID, FilterID   // same shape

public struct WriterGroup: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable { case user, inbox, trash }   // one row each for inbox/trash
    public var id: GroupID; public var parentID: GroupID?; public var name: String
    public var iconName: String                                      // SF Symbol
    public var sortIndex: Int; public var kind: Kind
    public var createdAt: Date; public var updatedAt: Date
}

public struct WriterDocument: Codable, Equatable, Identifiable, Sendable {   // a Ulysses "sheet"
    public var id: DocumentID; public var groupID: GroupID
    public var title: String            // derived by TitleDeriver on every save; stored for lists
    public var snippet: String          // first ~160 chars after the title line
    public var sortIndex: Int; public var isFavorite: Bool
    public var keywords: [String]       // Ulysses keywords, lower-cased, unique
    public var goal: WritingGoal?
    public var fileRelativePath: String // relative to the library root (Q3)
    public var wordCount: Int; public var characterCount: Int
    public var revision: Int64          // bumps per saved text change
    public var createdAt: Date; public var updatedAt: Date; public var trashedAt: Date?
}

public struct WritingGoal: Codable, Equatable, Sendable {
    public enum Unit: String, Codable { case words, characters, sentences, readingMinutes }
    public enum Mode: String, Codable { case atLeast, atMost, about }
    public var unit: Unit; public var target: Int; public var mode: Mode
}

/// Web-Annotation style anchor: exact offsets, then quote + context for re-anchoring.
public struct TextAnchor: Codable, Equatable, Sendable {
    public var start: Int; public var end: Int        // UTF-16 offsets at save time
    public var exact: String                          // the anchored text, capped 512 chars
    public var prefix: String; public var suffix: String   // ≤ 32 chars each
}

public struct WriterNote: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable { case typed, mention, intent, voice }
    public var id: NoteID; public var documentIDs: [DocumentID]   // empty = unattached, lives in Inbox; several = routed to several sheets (Pen)
    public var text: String; public var source: Source
    public var anchor: TextAnchor?                             // where in the document it was made
    public var createdAt: Date; public var updatedAt: Date
}

public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable { case needsWork, expand, cut, keep, comment }
    public enum Source: String, Codable { case voice, manual }
    public var id: AnnotationID; public var documentID: DocumentID
    public var kind: Kind; public var source: Source
    public var noteID: NoteID?          // `.comment` points at the WriterNote holding the text
    public var anchor: TextAnchor; public var createdAt: Date
}

public struct AuthorshipSpan: Codable, Equatable, Sendable {
    public enum Source: Codable, Equatable { case author, pasted, ai(model: String) }
    public var range: TextRange          // UTF-16 [start, end)
    public var source: Source; public var createdAt: Date
}
public struct TextRange: Codable, Equatable, Sendable { public var start: Int; public var end: Int }

public struct WriterFilter: Codable, Equatable, Identifiable, Sendable {   // Ulysses smart filter
    public var id: FilterID; public var scopeGroupID: GroupID?   // nil = whole library
    public var name: String; public var predicate: FilterPredicate; public var sortIndex: Int
}
public struct FilterPredicate: Codable, Equatable, Sendable {
    public var keywordsAll: [String]; public var searchText: String?
    public var favoritesOnly: Bool; public var modifiedWithin: TimeInterval?
}

public enum DocumentSort: String, Codable, CaseIterable { case manual, titleAscending, modifiedDescending, createdDescending }

public struct NoteHit: Equatable, Sendable { public let noteID: NoteID; public let score: Double; public let snippet: String }
public struct DocumentHit: Equatable, Sendable { public let documentID: DocumentID; public let score: Double }
```

Every id type wraps a UUID; enum columns in SQLite carry no CHECK (unknown
raw → safe default in Swift, the saves.sqlite rule).

## 4. `LunaWriterText`

All pure, all testable on macOS-style unit tests inside `LunaTests`.

- **`MarkdownScanner`** — incremental block + inline tokenizer, no dependency.
  ```swift
  public struct BlockToken: Equatable { public var lineRange: NSRange; public var kind: BlockKind; public var markupRanges: [NSRange] }
  public enum BlockKind: Equatable { case heading(level: Int), paragraph, blockquote(depth: Int),
      listItem(ordered: Bool, indent: Int, task: TaskState?), fencedCode(language: String?), fenceDelimiter,
      thematicBreak, tableRow(isHeader: Bool), tableDelimiter, footnoteDefinition(label: String), blank }
  public struct InlineToken: Equatable { public var range: NSRange; public var kind: InlineKind; public var markupRanges: [NSRange] }
  public enum InlineKind: Equatable { case emphasis, strong, strikethrough, highlight /* ==x== */, code,
      link(destination: String), image(destination: String), autolink, footnoteReference(label: String), hardBreak }
  public struct ScanState: Equatable { var inFence: String?  /* fence marker */; var inTable: Bool }
  public struct LineScan { public var block: BlockToken; public var inlines: [InlineToken]; public var stateAfter: ScanState }
  public func scanLine(_ line: Substring, at range: NSRange, state: ScanState) -> LineScan
  ```
- **`MarkdownDocumentModel`** — owns a `LineTable` (line start offsets, updated by
  `apply(edit: NSRange, replacementLength:)` in O(lines touched)) and one `LineScan`
  per line. `rescan(afterEditIn: NSRange) -> NSRange` rescans from the first edited
  line until a line's `stateAfter` equals its previous value (fenced code closes
  propagate exactly as far as they must). Exposes `block(at offset)`, `blocks(in:)`,
  `inlines(in:)`, `headings()` (outline), `firstHeadingText()`.
- **`SentenceSegmenter`** — `NLTokenizer(unit: .sentence)` per paragraph, cached by
  paragraph hash. `sentenceRange(containing:)`, `sentences(in paragraph:) -> [NSRange]`.
  Merges gazeread's abbreviation guard (`Mr.`, `Dr.`, initials) on top of NL.
- **`WordSegmenter`** — `NLTokenizer(unit: .word)`, `words(in sentence:) -> [NSRange]`,
  punctuation excluded. Feeds statistics, POS, reading tracker.
- **`PartOfSpeechTagger`** — `NLTagger(tagSchemes: [.lexicalClass])`, options omit
  punctuation/whitespace. `tags(in paragraph: NSRange, of text: String) -> [POSSpan]`
  with `POSClass: noun, verb, adjective, adverb, pronoun, conjunction, preposition, determiner, other`.
  Runs on a utility queue via `POSTaggingService` (cancellable per paragraph, LRU
  cache 256 paragraphs). Language detection gates it: unsupported → empty.
- **`TextStatistics`** — `measure(_ text: String, range: NSRange? = nil) -> Stats`
  (words, characters with/without spaces, sentences, paragraphs, reading time at
  238 wpm). Whole-doc on a 300 ms debounce; selection on demand.
- **`TextAnchorResolver`** — `make(range:in:) -> TextAnchor`; `resolve(_:in:) -> NSRange?`
  three tiers: exact offsets whose text equals `exact`; nearest occurrence of
  `prefix+exact+suffix` then `exact` alone within ±2 000 chars of `start`; else
  fuzzy (Levenshtein ≤ 10 % of length on candidate windows). `nil` = orphaned.
- **`TitleDeriver`** — first heading's text, else first non-empty line (trimmed of
  markup), else `L10n "WriterDocument_untitledTitle"`. Also `snippet(after title)`.
- **`MarkdownHTMLRenderer`** — full-document renderer over `MarkdownDocumentModel`
  for export and PDF (headings, lists, quotes, code, tables, footnotes, images by
  path). Not a live preview.
- **`MarkdownEditingCommands`** — pure text transforms used by the toolbar:
  `toggleWrap(range, marker:)`, `setHeading(level, paragraph:)`, `toggleList(kind:)`,
  `toggleTask`, `continueList(onReturnAt:)` (auto-continue bullets / numbering),
  `indent/outdent`. Return `[TextEdit]`, applied through the undo manager.

## 5. `LunaWriterStorage`

### 5.1 `WriterDatabase`
System `libsqlite3`, one connection per process behind a serial queue, WAL,
`busy_timeout 5000`, `foreign_keys = ON`, `user_version` migrations.
Location: `Application Support/LunaWriter/writer.sqlite` (no App Group).

```sql
groups(id TEXT PK, parent_id TEXT REFERENCES groups ON DELETE CASCADE, name, icon, sort_index INT, kind, created_at, updated_at)
documents(id TEXT PK, group_id TEXT NOT NULL REFERENCES groups, title, snippet, sort_index INT, favorite INT,
          goal_unit, goal_target INT, goal_mode, file_path, word_count INT, char_count INT, revision INT,
          created_at, updated_at, trashed_at)                       -- trash = group kind 'trash' + trashed_at
document_keywords(document_id REFERENCES documents ON DELETE CASCADE, keyword, PRIMARY KEY(document_id, keyword))
documents_fts  fts5(title, body, content='', tokenize='unicode61 remove_diacritics 2')   -- body indexed on save
notes(id TEXT PK, text, source, anchor_document_id TEXT REFERENCES documents ON DELETE SET NULL,
      anchor_start INT, anchor_end INT, anchor_exact, anchor_prefix, anchor_suffix, created_at, updated_at)
note_documents(note_id REFERENCES notes ON DELETE CASCADE, document_id REFERENCES documents ON DELETE CASCADE,
      attachment /* routed | created | manual | mention | voice */, PRIMARY KEY(note_id, document_id))
notes_fts      fts5(text, content='notes', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2')  + sync triggers
note_embeddings(note_id TEXT PK REFERENCES notes ON DELETE CASCADE, model_version, dims INT, vector BLOB)
document_embeddings(document_id TEXT PK REFERENCES documents ON DELETE CASCADE, model_version, dims INT, vector BLOB)
annotations(id TEXT PK, document_id REFERENCES documents ON DELETE CASCADE, kind, source, note_id REFERENCES notes ON DELETE CASCADE,
            anchor_start INT, anchor_end INT, anchor_exact, anchor_prefix, anchor_suffix, created_at)
authorship_spans(document_id REFERENCES documents ON DELETE CASCADE, start INT, end INT, source, model, created_at)
filters(id TEXT PK, scope_group_id REFERENCES groups ON DELETE CASCADE, name, sort_index INT, search_text, favorites_only INT, modified_within REAL)
filter_keywords(filter_id REFERENCES filters ON DELETE CASCADE, keyword)
document_snapshots(document_id REFERENCES documents ON DELETE CASCADE, created_at, text)   -- last 20 per doc, on session close
```

### 5.2 Repositories (protocols, one production type each)
```swift
public protocol WriterLibraryStoring: AnyObject {
    func groups() throws -> [WriterGroup]
    func createGroup(name: String, icon: String, parent: GroupID?) throws -> WriterGroup
    func update(_ group: WriterGroup) throws; func delete(_ id: GroupID) throws          // moves docs to trash
    func moveGroup(_ id: GroupID, to parent: GroupID?, at index: Int) throws
    func documents(in group: GroupID, sort: DocumentSort) throws -> [WriterDocument]
    func documents(matching: FilterPredicate, scope: GroupID?) throws -> [WriterDocument]
    func favorites() throws -> [WriterDocument];   func recent(days: Int) throws -> [WriterDocument]
    func document(_ id: DocumentID) throws -> WriterDocument?
    func createDocument(in group: GroupID, title: String?) throws -> WriterDocument
    func update(_ document: WriterDocument) throws        // metadata only; text goes through DocumentTextStoring
    func moveDocument(_ id: DocumentID, to group: GroupID, at index: Int) throws
    func trash(_ id: DocumentID) throws; func restore(_ id: DocumentID) throws; func emptyTrash() throws
    func searchDocuments(_ text: String, limit: Int) throws -> [DocumentHit]
    func filters() throws -> [WriterFilter]; func save(_ filter: WriterFilter) throws; func deleteFilter(_ id: FilterID) throws
    var inboxGroupID: GroupID { get }; var trashGroupID: GroupID { get }
}
public protocol NoteStoring: AnyObject {
    func notes(for document: DocumentID) throws -> [WriterNote]; func unattachedNotes() throws -> [WriterNote]
    func note(_ id: NoteID) throws -> WriterNote?
    func insert(_ note: WriterNote) throws; func update(_ note: WriterNote) throws; func delete(_ id: NoteID) throws
    func attach(_ id: NoteID, to document: DocumentID, attachment: NoteAttachment) throws; func detach(_ id: NoteID, from document: DocumentID) throws
}
public protocol DocumentMarksStoring: AnyObject {      // per-document range-bearing data, replaced as a set
    func marks(for document: DocumentID) throws -> DocumentMarks     // annotations + authorship spans
    func replaceMarks(_ marks: DocumentMarks, for document: DocumentID) throws
}
public protocol DocumentTextStoring: AnyObject {
    func loadText(_ document: WriterDocument) throws -> String
    func saveText(_ text: String, for document: inout WriterDocument) throws   // bumps revision, updates file_path if title moved
    func deleteText(_ document: WriterDocument) throws
}
public protocol LibraryChangeObserving: AnyObject { func libraryDidChange(_ change: LibraryChange) }   // weak observers list
```
`SQLiteWriterLibrary` implements the first three over `WriterDatabase`.
`LibraryChange` is an enum (`.groups`, `.documents(in: GroupID)`, `.document(DocumentID)`,
`.notes(DocumentID?)`); repositories post it after each commit on the main queue.

### 5.3 Document text on disk (Q3 default)
- **`LibraryFileLayout`** — pure: `path(for document:, groups:) -> String`
  (`Library/<Group>/<Sub>/<Title>.md`), filename sanitising, collision suffix
  ` 2`, ` 3`, title-change and move produce a rename plan `[FileMove]`.
- **`FileDocumentTextStore: DocumentTextStoring`** — atomic writes via
  `Data.write(.atomic)` under `NSFileCoordinator`, applies `LibraryFileLayout`
  moves on save, records `file_path`.
- **`LibraryFolderWatcher`** — `DispatchSource.makeFileSystemObjectSource` on the
  library root + a 1 s coalesced deep scan (`FileManager.enumerator`) comparing
  mtimes/sizes to `documents.updated_at`/`revision`.
- **`ExternalChangeReconciler`** — new `.md` file → new document in the group the
  folder maps to (unknown folder → group created); changed file → reload text,
  re-derive title, re-anchor marks via `TextAnchorResolver`, snapshot the old text;
  deleted file → trash the document (text kept from the last snapshot). If an
  open `DocumentSession` has unsaved edits the reconciler defers and the session
  merges (three-way merge is out of scope: latest external wins, local kept as a
  snapshot; the session shows a toast).
- If Q3 flips to SQLite-only: `SQLiteDocumentTextStore` (a `document_text` table)
  replaces the three types above; nothing else changes.

### 5.4 Notes index and routing (Pen, made local)
```swift
public protocol SentenceEmbedding: AnyObject {      // seam; production = NLEmbedding.sentenceEmbedding(for: language)
    var modelVersion: String { get }; var dimensions: Int { get }
    func vector(for text: String) -> [Float]?
}
public struct NoteQuery: Equatable { public var text: String; public var scope: Scope; public var prefixMatchesLastToken: Bool; public var limit: Int
    public enum Scope: Equatable { case document(DocumentID), all } }
public protocol NoteIndexing: AnyObject {
    func index(_ note: WriterNote) throws; func remove(_ id: NoteID) throws
    func search(_ query: NoteQuery) throws -> [NoteHit]
    func related(to windowText: String, in document: DocumentID, limit: Int) throws -> [NoteHit]   // Pen NoteMatcher
    func rebuild() throws
}
```
`SQLiteNoteIndex`: `search` builds an FTS5 query the Pen way (tokens on
`[\p{L}\p{N}]+`, deduped, quoted, OR-joined, last token `"tok"*` when
`prefixMatchesLastToken`), scores `bm25()` through the logistic map, and when the
query has ≥ 3 tokens fuses a cosine over `note_embeddings`
(`HybridScorer.fuse(cosine:, bm25Rank:) = 0.75·c + 0.25·b`, cosine rescaled from
[0.10, 0.50]). `related(to:)` embeds the window AND its 120-char tail and takes
the best score per note (Pen's two-context trick). Vectors are `Float32` BLOBs;
cosine runs in Swift over ≤ a few thousand notes (fine; no ANN).

`NoteRouter` (Q4, Pen's `deterministicFallback` made local):
`route(_ text: String) throws -> [NotePlacement]` where
`NotePlacement { documentID, title, created: Bool }`. Order: (1)
`ExplicitNewDocumentPhrase.match(text)` ("new document:", "new doc:", "new idea:",
"fresh concept:", "start a new document", "create a new document") → create a sheet
in the Inbox with the remainder as title; (2) `retrieveCandidates(text, limit: 5)` —
fused cosine over `document_embeddings` (title + snippet + keywords, refreshed on
save with a 10 s debounce; a NEW sheet is indexed at once so the next intent can
see it) with `documents_fts` bm25 — attach to every candidate with score ≥ 0.45;
(3) else create a sheet titled `TitleFromWords.make(text, count: 6)` (title-cased)
and attach. `NoteCaptureSplitter.split(text)` runs first for captures over 500
chars: paragraphs become sub-notes (fragments < 80 chars fold into the previous),
over-long paragraphs are sentence-packed, hard cap 4 000 chars per note, ≤ 10
sub-notes, nothing dropped; each sub-note is routed on its own. There is no LLM
leg; a FoundationModels routing leg is a later option behind the same protocol.

### 5.5 Settings and services
- `WriterSettings` (UserDefaults, standard suite): `focusMode: off|sentence|paragraph`,
  `syntaxColouring: Bool`, `typewriterScrolling: Bool`, `font: ReaderFont`, `fontSize`,
  `lineWidth: narrow|medium|wide`, `showAuthorship: Bool`, `gazeEnabled`, `voiceEnabled`,
  `lastCalibrationGrade`. Posts `WriterSettings.didChange`.
- `WriterIntentServices` — Foundation API the intents call:
  `addNote(text:, to: DocumentID?) throws -> NoteAddResult(.document(WriterDocument) | .inbox)`,
  `createDocument(title:, text:, in: GroupID?)`, `recentDocuments(limit:)`,
  `documents(matchingTitle:)`.
- `LibraryBootstrap` — first run: create Inbox and Trash rows, one "Welcome"
  sheet in Inbox that demonstrates Markdown, Focus, "@" and read-along.
- `WriterStorageStack` — builds everything from a root URL; `WriterWiring` and tests call it.

## 6. `LunaWriterEditor`

### 6.1 Text stack
`WriterTextView: UITextView`, created with `usingTextLayoutManager: true`
(TextKit 2; never touch `layoutManager`, that silently downgrades to TextKit 1 —
Pen's hard rule). `spellCheckingType = .no`, `inlinePredictionType = .no`,
`smartQuotesType/smartDashesType = .default`, `autocorrectionType = .default`,
`textContainerInset` from `EditorMetrics`, `alwaysBounceVertical`, no
`dataDetectorTypes`. Overrides `paste(_:)` (authorship), `canPerformAction`,
`buildMenu(with:)` (adds "Paste as AI text", "Mark as mine", "Add note here").

Two attribute channels, deliberately split:
- **Layout attributes** live in the text storage and change geometry: font per
  block/inline kind, paragraph style (heading spacing, list and quote indents,
  code block inset). Owned by `MarkdownTextStorage: NSTextStorage`, which keeps a
  `MarkdownDocumentModel` in step inside `processEditing` and restyles only the
  rescanned line range.
- **Rendering attributes** never change geometry and are applied to
  `NSTextLayoutManager` (`setRenderingAttributes(_:for:)`) for the viewport range
  only: foreground colour (Focus dim, syntax colours, authorship tint, markup
  grey), background (reading band, comment wash), underline (annotation colour).
  Owned by `RenderingAttributeComposer`.

### 6.2 Classes
- **`EditorMetrics`** — pure geometry: body font size → line height, heading
  scale table (iA-like: h1 1.6×, h2 1.35×, h3 1.15×, all others body), list
  indent (2.2 em), quote bar inset, `lineWidth` presets mapped through
  `LunaLayout.readableWidth` so a wide iPad still reads as a column.
- **`EditorTheme`** — colours resolved against a trait collection (registers for
  `LunaSkyTrait`): `ink`, `markup` (quaternary), `dimmed` (Focus), `caret`
  (iA blue `#1E90FF`-ish tuned for night), `codeBackground`, syntax colours
  (`noun`, `verb`, `adjective`, `adverb`, `conjunction`), authorship
  (`pasted` = `LunaColors.secondaryText`, `ai` = brand accent cooled),
  annotation colours (purple `#8A4FD6`, blue `#2F7FD6`, red `#D64A3C`,
  green `#3F9D59`, comment yellow `#E0B400` — gazeread's, lifted 10 % for night).
- **`MarkdownTextStorage: NSTextStorage`** — backing `NSMutableAttributedString`;
  `processEditing` → `model.apply(edit:)` → `model.rescan(afterEditIn:)` →
  `LayoutAttributeStyler.apply(model, to: self, in: rescannedRange)` (fonts from
  `ReaderFont`/`EditorMetrics`, paragraph styles), then `super.processEditing()`.
  Emits `MarkdownTextStorageDelegate.storage(_:didRescan: NSRange)` so rendering
  layers invalidate.
- **`RenderingAttributeLayer`** (protocol) — `var identifier: LayerID`,
  `func contributions(in range: NSRange, text: NSString) -> [RangedAttributes]`.
  Layers, in precedence order (later wins on the same key):
  1. `MarkupLayer` — markup ranges grey; code spans monospaced colour.
  2. `SyntaxColourLayer` — POS colours from `POSTaggingService` (async; applies when results arrive).
  3. `AuthorshipLayer` — pasted / AI tints when `showAuthorship`.
  4. `FocusLayer` — everything outside the focus range → `dimmed` (overrides 2–3).
  5. `AnnotationLayer` — underline style+colour per kind, comment wash (additive keys).
  6. `ReadingLayer` — installed by ReadAlong: active-sentence band background, read trail.
  **`RenderingAttributeComposer`** merges the layers for the viewport range
  (`NSTextViewportLayoutController.viewportBounds` + one screen of slack),
  re-applies on scroll end, on storage rescan, on layer invalidation
  (`LayerInvalidating.invalidate(_ range: NSRange?)`), coalesced to one pass per
  run-loop turn.
- **`FocusModeController`** — reads caret/selection from
  `UITextViewDelegate.textViewDidChangeSelection`, asks `SentenceSegmenter` /
  paragraph for the focus range, feeds `FocusLayer`; `typewriterScrolling` keeps
  the caret line at 45 % of the visible height by adjusting `contentOffset` with
  a short animation and a bottom `contentInset` so the last line can sit there.
  Focus dims only while the keyboard is up or the caret moved in the last 2 s
  (`FocusIdleTimer`), so a reader scrolling sees the whole text.
- **`AuthorshipTracker`** — owns `AuthorshipSpanList` (sorted, non-overlapping):
  `apply(edit: NSRange, replacementLength:, typedBy: Source)` splits/shrinks/
  extends spans in O(log n + k); typed characters extend an adjacent `.author`
  span or create one; `record(range:, source:)` for paste/AI/note insertions;
  `markAsOwn(range)`. Persisted through `DocumentMarksStoring` with the session.
- **`PasteInterceptor`** — inside `WriterTextView.paste(_:)`: reads
  `UIPasteboard.general` (string, else attributed → plain), inserts through the
  undo manager, records `.pasted`. "Paste as AI text" records `.ai(model: "pasteboard")`.
- **`AIWritingAssistant`** (Q6, `@available(iOS 26, *)`) — protocol
  `AIWritingAssisting { func continueWriting(context:) async throws -> String; func rewrite(_:) async throws -> String }`,
  production `FoundationModelsWritingAssistant` behind the gate, `nil` witness
  elsewhere; results inserted as `.ai(model:)` spans with a streaming insert.
- **`MentionController`** (the "@" system, Pen made inline) — state machine
  `idle → armed(markerLocation) → querying(query, results) → idle`.
  Arms when `shouldChangeTextIn` sees `"@"` typed with an empty selection at a
  word boundary (start of text, after whitespace or punctuation); the "@" IS
  inserted. Subsequent typing goes to the text view; `textViewDidChange` recomputes
  `query = text[marker+1 ..< caret]`, cancels if the caret leaves that range,
  the query exceeds 6 words, or contains a newline. Query → `NoteIndexing.search`
  (`scope: .document` first, `.all` merged below, `prefixMatchesLastToken: true`,
  limit 6) on a 120 ms debounce off-main; results → `MentionOverlayView`.
  Actions (Q5, peek only): `.peek(NoteID)` (Return on the highlighted row, or
  tap) opens `NotePeekCardView` over the text area — the note text, its sheet
  name, Edit, Close — and leaves `@query` in place until Close, which removes it
  and restores the caret; `.createNote(query)` (last row, or Return with no
  results) → `NoteStoring.insert` (`source: .mention`, attached to this sheet,
  anchor at the marker), removes `@query`, plays `NoteFlyInAnimator` toward the
  notes button (Pen's fly-in). The overlay never inserts note text into the
  sheet. Dismiss (Esc, tap outside, space-space, arrow away) leaves the typed
  text as plain text.
  Hardware keys: ↑/↓/Return/Esc via `UIKeyCommand`.
- **`MentionOverlayView`** — Liquid-Glass panel (`GlassStyle.focusPanel()`),
  anchored to the marker's caret rect, flips above when the keyboard would cover
  it (`KeyboardFrameObserver`), 6 rows of `NoteHitRow` (snippet, source glyph,
  document name when from another sheet), "New note" row. Width = min(360,
  text column width). Never takes first responder.
- **`RelatedNotesRanker`** — Pen's `NoteMatcher`: 400-char trailing window before
  the caret, 500 ms debounce, skip when unchanged, cancels in flight, calls
  `NoteIndexing.related(to:in:)`, publishes `[NoteID: Double]` and `topMatch` to
  `RelatedNotesObserving` (the strip above the keyboard and the notes panel).
- **`SentenceGeometryProvider`** — the seam ReadAlong needs:
  `func layout(for range: NSRange) -> [SentenceLayout]` where
  `SentenceLayout { index, textRange, lineRects: [CGRect], words: [WordLayout(range, rect)] }`
  in **text-container coordinates** (scroll-independent, gazeread's document
  coords), computed with `NSTextLayoutManager.enumerateTextSegments(in:type:.standard)`
  and cached until the storage rescans the range. Also `visibleSentences()`
  and `nearestSentence(toY:)`.
- **`EditorAccessoryBar`** — `inputAccessoryView`: heading, bold, italic, list,
  task, quote, link, code, "@", Focus toggle, statistics; a `UIScrollView` of
  `GlassStyle.circularButtonConfiguration` buttons; hidden on iPad with a hardware
  keyboard (shortcuts ⌘B/⌘I/⌘K/⌘⇧F…). The **related-note strip** (one line,
  Pen's grab bar) sits above it when `topMatch` exists.
- **`StatisticsBarView`** — word count, reading time, goal ring
  (`MoonHorizonProgress` reused), tap → `StatisticsSheet`.
- **`DocumentSession`** — one per open document: loads text + marks, owns the
  `MarkdownTextStorage`, `AuthorshipTracker`, `AnnotationSet` (re-anchored on load,
  orphans listed), autosave (1 s debounce after last edit, on background, on close)
  through `DocumentTextStoring` + `DocumentMarksStoring`, derives title/snippet/
  counts and updates `WriterDocument`, takes a snapshot on close if changed.
  `DocumentSessionDelegate` (weak): `sessionDidSave`, `sessionDidReanchor(orphans:)`,
  `sessionDidReceiveExternalChange`.
- **`EditorViewController`** — hosts all of the above for one `DocumentSession`.
  Public API used by the organiser: `init(session:, environment: EditorEnvironment)`,
  `var delegate: EditorViewControllerDelegate?` (weak: `editorRequestsNotesPanel`,
  `editorDidUpdateDocument`), `func focus(on anchor: TextAnchor)`,
  `func installOverlayLayer(_:)` / `removeOverlayLayer`, `var sentenceGeometry: SentenceGeometryProvider`,
  `var readAlongHost: UIView` (a passthrough layer above the text for the band/HUD).
  `EditorEnvironment` bundles the witnesses: `noteIndex`, `noteStore`, `marksStore`,
  `settings`, `aiAssistant?`.

## 7. `LunaGaze` (extracted) and `LunaWriterReadAlong`

### 7.1 Extraction
Move `GazeTracker.swift`, `GazeCalibration.swift`, `GazeScreenProjection.swift`
and the `GazeSample` type from `LunaReaderUI` into a new `LunaGaze` target;
`LunaReaderUI` depends on it and `@_exported import LunaGaze` so no call site or
test changes. `GazeAttentionPolicy`/`RSVPGazeCoordinator` stay in the Reader.

### 7.2 New in `LunaGaze` (all pure except the tracker)
- `OneEuroFilter` (minCutoff 1.0, beta 0.007, dCutoff 1.0) for `CGPoint` streams.
- `FixationDetector` — I-DT: dispersion threshold and min duration in points and
  seconds; defaults derived from visual angle (`VisualAngle.points(degrees:, distance:, idiom:)`
  over `GazeScreenProjection.pointsPerMetre`): dispersion 1.3°, minDuration 70 ms, maxGap 220 ms.
  `func ingest(_ point: CGPoint, at time: TimeInterval) -> Fixation?`.
- `GazeGate` — blink (ARKit blendshapes `eyeBlinkLeft/Right` > 0.45), face lost
  350 ms, off-screen slop 1.5° → `GateReason: ok, blink, away, offScreen`.
- `GazeAffineCalibration` — model `screen = A·raw + b` (A 2×2, b bias) fitted by
  ridge regression toward the identity prior (λ 0.5 on A, 0 on b), two-pass outlier
  drop (median + 2.5·MAD), lag search over {60,100,140,180,220,260} ms, plus
  `validate(points:) -> CalibrationVerdict(meanError, worstQuadrant, degrees, grade)`
  with grades Good < 1.2°, Usable < 2.2°, Rough. `Codable`, persisted per
  orientation by `GazeCalibrationStore` (UserDefaults). Bias-only online nudge
  `nudge(toward: CGVector, gain:)` clamped to ±220 pt.
- `PursuitCalibrationPath` — port of `calibrate-path.js`: `full(in bounds)`
  (3-row rounded lawnmower, hold 900 ms, corner pause 420 ms, speed clamp
  250–600 pt/s, ≈ 16 s), `quick(in:)` (one S-curve ≈ 7 s), `region(quadrant, in:)`;
  `position(at time:) -> CGPoint`, `validationPoints` at (0.22/0.78, 0.24/0.76).
- `CalibrationSampleCollector` — pairs tracker samples with path positions,
  drops blink frames (> 0.3) and saccade frames (velocity > 0.3 units/s, and the
  landing frame), buffers by lag.
- `ReadingTracker` — port of gazeread's `Reader`, pure and clocked by the caller:
  ```swift
  public struct ReadingTrackerConfiguration { sigmaYDegrees = 2.0, sigmaXFactor = 4.2, switchDelay = 0.48,
      initialWPM = 230, wpmBounds = 120...520, snapDwell = 0.40, snapMinIndexDelta = 5,
      autoAdvance = (gazeLow: 0.9, gazeHigh: 1.4, auto: 0.26), qualityFloor = 0.22, qualityDropDelay = 2.5 }
  public struct ReadingState: Equatable { activeSentence: Int?; readUpToWord: Int; cursorWord: Int?; mode: Mode; quality: Double; residual: CGFloat }
  public final class ReadingTracker { init(configuration:, pointsPerDegree:)
      func setLayout(_ sentences: [SentenceLayout]); func ingest(gaze: CGPoint?, gate: GateReason, at: TimeInterval)
      func tick(at: TimeInterval) -> ReadingState; func resetTo(sentence:); var state: ReadingState }
  ```
  Scoring, transition prior, switch debounce, sweep, snap and auto-advance follow
  the JS constants exactly, in points scaled by `pointsPerDegree`.
- `GazeDriftCorrector` — vertical nudge toward the active sentence when quality
  ≥ 0.5 and the gap is 18–170 pt equivalents (gain 0.12 after a user scroll settles,
  0.03 every 1.2 s); recalibration nag when the residual stays > 3° for 10 s or
  the view size changes > 20 %.

### 7.3 `LunaWriterVoice`
- `SpeechTranscribing` (protocol): `start()`, `stop()`, `var delegate: SpeechTranscribingDelegate?`
  with `onset()` and `utterance(_ text: String)`.
  - `SFSpeechTranscriber` (iOS 18): `AVAudioEngine` input tap → `SFSpeechAudioBufferRecognitionRequest`
    with `requiresOnDeviceRecognition = true` (fails closed if the locale has no
    on-device model), `shouldReportPartialResults = true`; utterance boundary =
    `isFinal` or 400 ms without a new partial (`UtteranceSegmenter`); 20 s cap.
  - `SpeechAnalyzerTranscriber` (`@available(iOS 26, *)`): `SpeechAnalyzer` + `SpeechTranscriber`
    volatile/final results, same segmenter.
  - `EnergyVAD` on the tap buffer (RMS over 30 ms frames, threshold −38 dBFS,
    250 ms pre-roll, 400 ms hangover) fires **`onset()`** before the recogniser has
    any partial — the anchor snapshot must be early, as gazeread's VAD is.
- `VoiceCommandClassifier` — port of `classify()`: lexicon per `Annotation.Kind`,
  normalisation, Levenshtein tolerance by word length (0 / 1 at 5–7 / 2 at ≥ 8),
  single-word phrases only when the utterance ≤ 4 tokens, multi-word phrases
  when ≤ 8 tokens contiguous or ≤ 6 tokens as a stop-word-free set; otherwise
  `.comment(text)`; empty/punctuation → `nil`. `VoiceCommandClassifierTests`
  carries the `test/classify.mjs` table verbatim.
- `VoicePermissions` — microphone + speech authorisation, asked at the moment the
  user turns voice on (Luna's "ask at opt-in" rule), never at launch.

### 7.4 `LunaWriterReadAlong`
- `ReadAlongCoordinator` — owns one `GazeTracking` (from `LunaGaze`), the
  `GazeAffineCalibration`, `OneEuroFilter`, `FixationDetector`, `GazeGate`,
  `ReadingTracker`, `GazeDriftCorrector`, and one `SpeechTranscribing`. Per frame:
  raw ARKit sample → projected screen point (`GazeScreenProjection`) → calibrated →
  filtered → text-container coordinates (through the editor's scroll offset) →
  `ReadingTracker.ingest`. On `CADisplayLink` tick: `tracker.tick` → `ReadingLayer`
  (band + read trail) and scroll assist. Speech `onset()` → `anchor = tracker.state`
  → line range of the cursor word (words on the same visual line), else the
  sentence nearest 45 % of the viewport; `utterance(text)` → classifier →
  `.highlight(kind)` → `Annotation(kind, .voice, anchor)`; `.comment` →
  `WriterNote(.voice, anchor)` + `Annotation(.comment, noteID)`; both through
  `DocumentMarksStoring`/`NoteStoring` and the `AnnotationLayer`. Toast "heard: …".
  `ScrollAssist`: keeps the active sentence within 24–68 % of the viewport, max
  18 pt/frame, never within 1.4 s of user interaction.
- `ReadAlongState` — value type mirroring Luna Reader's `EyeTrackingState`
  discipline: `gazeEnabled` (durable), `voiceEnabled` (durable), `trackingLost`,
  `calibrationGrade`; drives the HUD.
- `ReadAlongHUDView` — the gazeread chip: a `GlassStyle` pill at the card's top
  trailing edge with a tracking dot and a mic dot; menu: Calibrate (~25 s), Quick
  touch-up (~8 s), Pause tracking, Voice comments on/off, Diagnostics overlay,
  Clear annotations.
- `GazeCalibrationViewController` — full-screen: intro → pursuit dot (`CAShapeLayer`
  along `PursuitCalibrationPath`) → head-turn stage (7 s) → fit → 4-point
  validation → verdict with "Touch up <quadrant>". Quick and regional variants.
  Esc / swipe-down cancels. Grade shown in degrees, never px.
- `ReadingLayer` (a `RenderingAttributeLayer`) and `ReadAlongOverlayView`
  (gaze dot / fixation / per-sentence score bars for the diagnostics mode, drawn in
  `readAlongHost`).
- `AnnotationPresenter` — tap on an annotated range → `AnnotationPopover`
  (re-colour, edit comment, delete); selection edit-menu items "Needs work /
  Expand / Cut / Keep / Comment" for manual annotations (source `.manual`).
- `ReadAlongAvailability` — TrueDepth + not an appex (`GazeTrackingAvailability`)
  gates the gaze half; voice is independent.

## 8. `LunaWriterLibraryUI` (Ulysses)

- `LibraryRootViewController: UISplitViewController(style: .tripleColumn)` —
  primary `GroupsViewController`, supplementary `SheetsViewController`, secondary
  `EditorContainerViewController`. Compact widths collapse to a navigation stack
  (UIKit does this). `preferredDisplayMode = .twoBesideSecondary` when the width
  passes `LunaLayout.isWide`, else `.oneBesideSecondary`.
- `GroupsViewController` — `UICollectionView` with `.sidebar` list layout and
  `NSDiffableDataSourceSectionSnapshot` for nesting. Sections: Library (All,
  Last 7 Days, Favorites), Inbox (with unattached-note count badge), Groups
  (expandable, filters as children), Trash. Drag-and-drop to reorder/move groups
  and to drop sheets onto groups. Context menu: New Group, New Filter, Rename,
  Change Icon (`GroupIconPickerViewController`, a curated SF Symbols grid),
  Delete. Empty-state copy through `L10n`.
- `SheetsViewController` — `UICollectionView` list of `SheetCell` (title, snippet,
  relative date, goal ring, favourite dot, keyword chips). Header: sort menu,
  search field (`WriterLibraryStoring.searchDocuments` over `documents_fts`),
  New Sheet. Swipe: Favourite, Move (`MoveDestinationPicker`), Trash. Multi-select
  → Move / Trash / Keyword. Manual sort via drag. Inbox shows a second section of
  unattached notes (`UnattachedNoteCell`: text, source glyph, "Attach to…").
- `EditorContainerViewController` — `NavHeaderBar` (back, title from the session,
  notes button with count, read-along chip host, ⋯ menu: Share/Export, Statistics,
  Keywords, Goal, Move, Favourite, Trash, Snapshots). Hosts `EditorViewController`
  and, when gaze or voice is enabled, the `ReadAlongCoordinator`. On wide layouts
  the notes panel is a side child (not a modal — the touches next door matter,
  `claudedocs/readers.md`); compact → sheet.
- `DocumentNotesPanelViewController` — notes for the sheet ordered by
  `RelatedNotesRanker` scores when present, else recency; rows show anchor text
  when anchored, tap → `focus(on: anchor)`; compose field at the bottom
  (`source: .typed`); swipe to delete; orphaned anchors marked.
- `KeywordEditorViewController`, `GoalEditorViewController`, `SnapshotsViewController`
  (list of `document_snapshots`, preview, Restore).
- `DocumentExporter` — Markdown (the file), plain text (markup stripped by the
  scanner), HTML (`MarkdownHTMLRenderer` + a night/paper stylesheet), PDF
  (`UIMarkupTextPrintFormatter` → `UIGraphicsPDFRenderer`); presented through
  `LunaShareSheet`.
- `WriterSettingsViewController` — sections: Editor (font, size, line width,
  Focus, syntax colours, typewriter, authorship visibility), Read-along (gaze,
  voice, Calibrate, last grade), Library (storage location, snapshots count),
  Appearance (`AppearanceSettings`), About. Grouped table with `NavHeaderTableController`.
- `WriterOnboardingCard`? No: the Welcome sheet is the onboarding.

## 9. App Intents (`LunaWriter/Intents/`)
Definitions stay in the app target (metadata extraction); logic is
`WriterIntentServices` in Storage.

- `AddWriterNoteIntent: AppIntent` — `title = "WriterIntents_addNote_title_Luna"`,
  `@Parameter(title: "WriterIntents_addNote_text_Luna") var text: String`,
  `@Parameter(title: "WriterIntents_addNote_document_Luna") var document: WriterDocumentEntity?`,
  `openAppWhenRun = false`, `perform` → `addNote` → `.result(dialog:)` "Added to
  <title>" / "Added to your Inbox"; `WidgetCenter` not involved (no widget).
- `CreateWriterDocumentIntent` (`title?`, `text?`, `group?`) → opens the app on
  the new sheet via `lunawriter://document/<id>`.
- `OpenWriterDocumentIntent(document)`; `WriterDocumentEntity: AppEntity` with
  `WriterDocumentQuery: EntityStringQuery` (title search, `suggestedEntities` =
  10 most recent).
- `WriterShortcuts: AppShortcutsProvider` — "Add a note to ${applicationName}",
  "Take a note in ${applicationName}", "New sheet in ${applicationName}".
- Deep links: `lunawriter://new`, `lunawriter://document/<uuid>`,
  `lunawriter://note/<uuid>`, handled by `WriterDeepLinkRouter` in the scene delegate.

## 10. App shell (`LunaWriter/`)
- `WriterAppDelegate` — `WriterWiring.install()`, scene configuration.
- `WriterSceneDelegate` — `AppearanceSettings.apply(to: window)`, root =
  `WriterWiring.makeRootViewController()`, URL contexts → `WriterDeepLinkRouter`,
  background → `WriterWiring.applicationDidEnterBackground()` (flush sessions).
- `WriterWiring` (`@MainActor enum`) — builds `WriterStorageStack` at
  `Application Support/LunaWriter` and `Documents/Library`, installs witnesses
  (`NoteIndexing`, `SentenceEmbedding` = `NLSentenceEmbedding`, `SpeechTranscribing`
  factory by OS, `AIWritingAssisting?`), starts `LibraryFolderWatcher`, exposes
  `makeRootViewController()`.
- `Info.plist`: `NSCameraUsageDescription` (gaze), `NSMicrophoneUsageDescription`,
  `NSSpeechRecognitionUsageDescription`, `UIFileSharingEnabled`,
  `LSSupportsOpeningDocumentsInPlace`, `CFBundleURLTypes lunawriter`, scene
  manifest, `UILaunchScreen` with `LunaColors.background`. No App Group, no
  background modes.
- `LunaWriter.entitlements` — empty dict (own file per app, the rule).
- `AppIconWriter` — placeholder PNG set generated by
  `scripts/make_writer_placeholder_icon.swift` (a nib glyph on the Luna night).
- `-LunaStage` catalog `Stage/StageCatalog+Writer.swift` with: library populated /
  empty, editor with focus / syntax / authorship, mention overlay open, read-along
  HUD, calibration verdict — compiled only into `LunaWriter` (kind-pack rule).

## 11. Tests (`LunaTests`, plan `LunaWriter.xctestplan`, scheme `LunaWriterTests`)
Behaviour only, no constant echoes.

| Suite | Asserts |
| --- | --- |
| `WriterMarkdownScannerTests` | block/inline tokens on a fixture corpus; incremental rescan after random edits equals a full rescan (property test, 500 edits) |
| `WriterTextAnchorResolverTests` | exact, shifted, edited-nearby, orphaned |
| `WriterSegmenterTests` | sentence ranges with abbreviations/quotes; word ranges skip punctuation |
| `WriterStatisticsTests` | counts and reading time on fixtures |
| `WriterTitleDeriverTests` | heading, first line, untitled |
| `WriterDatabaseTests` | migrations, cascade deletes, trash/restore/empty, move/reorder, filters |
| `WriterNoteIndexTests` | prefix query hits, OR recall, hybrid ordering with a fake embedding, related-window best-of-two |
| `NoteRouterTests` | explicit phrase → new sheet; ≥ 0.45 attaches to all candidates; else new sheet titled from six words; splitter table (paragraphs, folding, sentence packing, ≤ 10, nothing dropped) |
| `LibraryFileLayoutTests` | paths, collisions, rename plans; reconciler on add/change/delete in a temp dir |
| `AuthorshipSpanListTests` | typing inside/at edges of foreign spans, deletes, paste, mark-as-own |
| `MentionControllerTests` | arm rules, query tracking, cancel rules, insert/create/peek outcomes on a real `WriterTextView` |
| `RenderingAttributeComposerTests` | precedence (focus dims syntax; annotation underline survives) |
| `MarkdownTextStorageTests` | fonts/paragraph styles per block after edits; fence propagation |
| `FocusModeControllerTests` | focus range follows caret; idle timer clears dim |
| `VoiceCommandClassifierTests` | the `classify.mjs` table + fuzzy cases |
| `UtteranceSegmenterTests` | final / silence boundaries, 20 s cap |
| `FixationDetectorTests`, `OneEuroFilterTests` | synthetic streams |
| `GazeAffineCalibrationTests` | recovers a known affine + bias under noise; outlier drop; lag search; grades |
| `PursuitCalibrationPathTests` | monotone time, speed clamp, waypoint holds |
| `ReadingTrackerTests` | port of `sim.mjs`: band accuracy under head pose deltas, switch debounce, regression snap, auto-advance |
| `WriterIntentServicesTests` | add note with/without document, create document |
| `WriterDocumentSessionTests` | autosave debounce, external change re-anchor, snapshots |
| `WriterStageRegistryTests` | manifest pins the Writer stages |

`select_changed_tests.py` gets rows for `LunaLibraries/Sources/LunaWriter*`,
`LunaLibraries/Sources/LunaGaze`, `LunaWriter/`.

## 12. Work packages and agents

WP0 is done in the primary worktree before any agent starts, so no agent edits
`Package.swift` or `project.pbxproj` (memory: `luna-module-agent-workflow`).
Every agent gets: pinned base SHA + `git reset --hard`, its own worktree, "do not
merge, do not delete the worktree", "xcodebuild in the FOREGROUND only, timeout
600000 ms", compile gate = `xcodebuild build-for-testing -scheme Luna …`, and
"commit in small logical chunks".

| WP | Content | Model | Wave |
| --- | --- | --- | --- |
| 0 | scaffold: 8 package targets, `LunaGaze` extraction, `LunaApp.writer` + `_Writer` suffix, app target/scheme/testplan/pbxproj, folders with `Module.swift` stubs, this plan | me | 0 |
| A | `LunaWriterText` complete + tests | opus | 1 |
| B | `LunaWriterStorage` complete (DB, repos, file layout/watcher/reconciler, NoteIndex, NoteRouter, settings, intent services, bootstrap) + tests | opus | 1 |
| C | `LunaWriterVoice` (transcribers, VAD, segmenter, classifier, permissions) + tests | sonnet | 1 |
| D | `LunaGaze` additions (filters, gate, affine calibration, pursuit path, collector, ReadingTracker, drift corrector) + tests incl. the `sim.mjs` port | opus | 1 |
| E | `LunaWriterEditor` (everything in §6) + tests | opus | 2 |
| F | `LunaWriterLibraryUI` (§8) built against E's public API from this plan; the detail column takes an `EditorHosting` protocol until E lands | sonnet | 2 |
| G | `LunaWriterReadAlong` (§7.4) against D, C and E's `SentenceGeometryProvider` | opus | 2 |
| H | app shell, intents, wiring, Info.plist, icon script, stage catalog, strings entries, `claudedocs/writer.md` | sonnet | 3 |
| I | mechanical: strings `_Luna` entries sweep with `strings_sync.py`, `select_changed_tests.py` rows, `hide_generated_schemes.rb`, doc index lines | haiku | 3 |
| J | integration in the primary worktree: merge in dependency order (A B C D → E → F G → H I), fresh-sim full suite, on-device smoke of gaze + voice, fix-ups | me | 3 |

Wave 1 runs four agents in parallel (≈ 3.5 GB derived data each; 93 GB free).
Wave 2 starts when A, B, D are merged; F may start with wave 1 on stubs.

## 13. Risks
- **TextKit 2 rendering attributes** are documented but thinly exercised on iOS;
  if `setRenderingAttributes` proves unreliable for background colour, the
  `ReadingLayer` band falls back to a `CAShapeLayer` in `readAlongHost` drawn from
  `SentenceGeometryProvider` (same geometry, no attribute).
- **ARKit accuracy** for a full-page reading surface is unproven here; the Reader
  only asks "is the gaze near one word". The sentence-band design is the
  mitigation; the diagnostics overlay and session trace exist to tune σ.
- **On-device speech** availability varies by locale; the voice toggle shows the
  reason when `supportsOnDeviceRecognition` is false and never falls back to the
  server recogniser.
- **`NLEmbedding` sentence vectors** are English-first; the index degrades to pure
  FTS elsewhere by design.
- **File layout + external edits** is the largest non-UI surface (Q3); the
  protocol seam lets it be swapped for SQLite text without touching the UI.
- **pbxproj by hand**: verified from an empty `-derivedDataPath` (clean build
  catches dangling references the warm build hides).
