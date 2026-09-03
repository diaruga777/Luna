# Luna Writer hardening — plan (2026-09-03)

A review of the whole Luna Writer app (six package modules plus the `LunaWriter/`
target) for simplification, bugs, performance, memory and threading, with two
specific asks: good iPad / screen-size / orientation support, and a codebase
that a Mac target can be composed from without a rewrite.

The six review reports are the source of truth for every finding, with exact
`path:line` references and proposed changes:

| Report | Covers |
| --- | --- |
| `writer-hardening/review-organiser-shell.md` | `LunaWriterLibraryUI`, `LunaWriter/` app target |
| `writer-hardening/review-editor.md` | `LunaWriterEditor` |
| `writer-hardening/review-text-models.md` | `LunaWriterText`, `LunaWriterModels` |
| `writer-hardening/review-storage.md` | `LunaWriterStorage`, `OpenSessionRegistry` |
| `writer-hardening/review-voice-gaze.md` | `LunaWriterVoice`, `LunaGaze` |
| `writer-hardening/review-readalong.md` | `LunaWriterReadAlong`, `WriterReadAlongWiring` |

This page is the work breakdown. Each work package (WP) names the files it owns,
the findings it closes (by report and number), the tests it must add, and its
acceptance bar. Packages in the same wave run in parallel in separate
worktrees and never edit the same file.

## 1. The headline defects

Ten things are broken in a way a user will hit on day one. Everything else is
quality.

1. **Unsaved edits are never flushed on background.** The app uses the scene
   lifecycle; the flush hangs off `applicationDidEnterBackground`, which UIKit
   does not call for a scene-based app. (organiser #1)
2. **Trashing a sheet, deleting a group, or emptying the Trash brings the
   sheets back as duplicates** on the next folder scan, because the `.md`
   files are left in the watched tree. (storage P0 ×3)
3. **Voice annotations are erased by the next autosave.** Read-along writes
   marks straight to SQLite while the open session holds its own set and
   replaces the row on save. (read-along #1)
4. **Every opened sheet leaks its editor, ARSession, microphone and display
   link.** The read-along session registry can never prune. (read-along #2,
   voice-gaze #31)
5. **Read-along never has geometry.** `refreshLayout()` runs before the first
   layout pass and never again, so no band draws and no voice annotation is
   ever stored. (read-along #8, editor geometry P1)
6. **Action sheets crash on iPad.** Four `UIAlertController(.actionSheet)`s are
   presented with no popover anchor. (organiser #12)
7. **Swipe actions on the sheets list never fire** — declared on the wrong
   delegate — and sheets have no context menu, so a sheet cannot be trashed,
   moved or favourited from the list except in Edit mode. (organiser #18, #19)
8. **Settings is unreachable.** Nothing constructs `WriterSettingsViewController`.
   (organiser #33)
9. **Calibration can never succeed.** The sample collector's `startTime` is
   fixed at 0 while frames carry uptime, so every sweep buffer stays empty.
   (voice-gaze #26)
10. **iOS 18 voice yields one utterance per session** and then goes silent
    while the HUD says it is listening. (voice-gaze #1, #2)

## 2. iPad, screen sizes, orientation

Findings, in order of user impact:

- Triple-column split forced at ≥ 700 pt starves the editor in iPad portrait
  (organiser #7). Screenshot evidence is recorded in §7.
- Action sheets without anchors (organiser #12).
- Keyboard frame converted from window rather than screen coordinates — wrong
  in Split View, Slide Over and Stage Manager (editor keyboard P1); non-local
  keyboard notifications accepted (editor P2).
- Typewriter line ignores the keyboard; bottom inset never reset (editor P1 ×2).
- No `viewDidLayoutSubviews`/`viewWillTransition`: sentence geometry,
  read-along band and the "@" overlay go stale on rotation and multitasking
  resize (editor geometry P1, read-along #8).
- Landscape gaze is wrong three ways: orientation never set, gate built with
  the portrait size, calibration read from the portrait slot (voice-gaze #20,
  #30; read-along #10). `viewportOrigin` is a window point compared against a
  screen point (read-along #11). Camera position assumed top-centre; iPad ppi
  table wrong for the mini (voice-gaze #18, #19). Rotation mid-calibration is
  undetected (read-along #20).
- Accessory bar's hardware-keyboard hide never fires on a Magic Keyboard iPad;
  the accessory keeps 80 pt when empty (editor P2 ×2).
- No keyboard commands at the organiser level; no sheet context menu; no
  persistent sidebar selection; blank column title for a group (organiser #11,
  #19, #8, #20).
- Notes panel compose bar pinned to the safe area, not the keyboard (organiser
  #30); presented notes sheet leaves stale state on swipe-dismiss (#13).
- Popover without a delegate becomes an undismissable modal on compact
  (read-along #26).

## 3. Mac portability

The pure tiers are already Mac-clean: `LunaWriterModels`, `LunaWriterText`,
`LunaWriterStorage` (one `.documentDirectory` assumption), and the pure half of
`LunaGaze`. Four couplings stop a Mac target from being a composition change:

1. `LunaWriterEditor` imports `LunaGaze` for `SentenceLayout`/`WordLayout`, and
   `LunaGaze` imports ARKit unguarded, so the editor tier cannot compile
   without ARKit. Move the two value types to `LunaWriterModels`; split
   `LunaGaze` into a pure core and an ARKit adapter behind
   `#if canImport(ARKit)` (platform gating inside one module, not the
   per-target gating CLAUDE.md forbids).
2. `ReadAlongCoordinator` and `GazeCalibrationViewController` default to
   `ARFaceGazeTracker()` and `UIScreen.main`. Replace with a `GazeTrackerMaking`
   witness installed by the root (nil → gaze half hidden, voice-only
   read-along anchors at the caret).
3. `EditorAccessoryBar` branches on `userInterfaceIdiom`; keyboard-frame
   notifications never fire on Mac. Introduce `AccessoryBarPolicy` and
   `KeyboardMetricsProviding` witnesses; rename `isKeyboardVisible` to
   `isComposing` driven by first-responder state.
4. No `buildMenu(with:)` / `UIKeyCommand` coverage at the organiser level; a
   Mac app with no File menu is unusable.

Acceptance for the Mac leg: `xcodebuild build -scheme LunaWriter -destination
'platform=macOS,variant=Designed for iPad'` succeeds, the app launches on the
Mac, opens a sheet, and read-along shows voice-only. Catalyst and a native
AppKit target stay out of scope; the seams above are what make either one a
composition change later.

## 4. Work packages

Conventions for every package:

- Work in the worktree you are given; it is already on `main`. Commit small
  logical chunks with the project's commit trailer. Do not merge; the lead
  merges.
- Every new user-visible string is a `"<Key>_Luna"` entry in
  `LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings`,
  read via `L10n.string`. Run `python3 scripts/strings_sync.py --write` and
  keep the file's hand-grouping.
- Comments follow the project standard: only where the code cannot speak.
  Delete the narrating comments the reports name.
- Wiring is protocol witnesses, never stored closures.
- Compile gate per commit: `xcodebuild build-for-testing -scheme Luna
  -destination 'generic/platform=iOS Simulator' -derivedDataPath <your DD>
  DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`. Run only YOUR suites on a
  simulator you create (`xcrun simctl create wp-<x> "iPhone 16" ` + the iOS
  26.x runtime) with `-only-testing:LunaTests/<Suite>`; shut it down when
  done. The lead runs the full suite after merging.
- A test asserts behaviour; no constant echoes, no source greps.

### Wave 1 (parallel)

#### WP-A1 — Files, watcher, reconciler (storage report)

Owns: `LunaWriterStorage/Files/*`, `LunaWriterStorage/LibraryBootstrap.swift`,
`LunaWriterStorage/WriterStorageStack.swift`, `LunaWriter/OpenSessionRegistry.swift`,
the trash/restore/delete/emptyTrash file moves in
`SQLiteWriterLibrary.swift` / `+Documents.swift` (coordinate: A2 owns the
rest of those two files; A1 adds only the file-move calls and the
`document(atPath:)` lookup).

Closes: storage P0 ×3 (trash/emptyTrash/deleteGroup leave files), P1 file
returns → restore not adopt, P1 group-folder rename by content hash, P1 NFC/NFD
path matching, P2 scan in one transaction, P2 `reanchorMarks` atomic, P3 cubic
`groupForFolder`; `FileDocumentTextStore` P1 write-before-remove, P1 encoding /
iCloud placeholder, P1 normalisation collision, P2 groups round trips, P2
coordinate the move, P3 suffix fallback; `LibraryFolderWatcher` P1
subdirectory blind spot (per-directory sources plus a foreground scan), P2
`deinit` deadlock, P3 root rename, P3 comment; `WriterStorageStack` P1
reconciler `main.sync` (lock-protected snapshot of unsaved ids), P1
`#if os(macOS)` guard on `makeDefault`; `LibraryBootstrap` P2 trash-aware.

Design: a `.Trash/` folder under the library root, excluded from `scan`;
`trash` moves the file there (keeping `file_path` pointing at the new
location), `restore` moves it back through `LibraryFileLayout.path`,
`emptyTrash` unlinks, `delete(group)` moves the subtree's files into `.Trash/`.

Tests: storage report "Test gaps" 1–5, 9–12.

#### WP-A2 — Database, repositories, indexes (storage report)

Owns: `LunaWriterStorage/Database/*`, `Repositories/*` (except the file-move
lines A1 adds), `Notes/*`, `WriterIntentServices.swift`, `WriterSettings.swift`.

Closes: `WriterDatabase` P1 statement cache (bind id lists via `json_each`,
LRU cap with finalize), P2 rollback check, P2 migration branch, P2 migrate
under `retryingWhileBusy`, P3 `userVersion`, P3 in-flight assertion;
`WriterSchema` P2 `documents(file_path)` index, P3 `end` → `end_offset`
(migration step 2); `+Documents` P1 `update` re-indexes (index becomes a
collaborator), P1 revision-guarded narrow writes (`setFavorite`, `setGoal`,
`setKeywords`), P2 FTS join in SQL, P2 `documents(matchingTitle:)` in SQL, P3
shared fan-in helper; `+Notes` P1 explicit anchor document + `ORDER BY`, P1
embedding refresh on `update` (index as collaborator), P3 double attach;
`+Marks` P2 `snapshotCount(for:)` + metadata-only list; `SQLiteNoteIndex` P1
rebuild guard order, P1 missing-row error, P2 delete `refreshFTS`, P2 batched
rebuild, P2 bind scope uuid, P2 serialise `NLEmbedding`, P3 bm25 once;
`SQLiteDocumentIndex` P2 `rebuild()`; `Scoring` P3 `loadUnaligned`;
`WriterSettings` P2 post on main; `WriterIntentServices` P3.

Also adds `sentenceCount` to `WriterDocument` (models) and the schema, filled
by `DocumentTextSummary` — B2 reads it for goals.

Tests: storage report "Test gaps" 6–8, 13–15.

#### WP-B1 — Organiser root, sidebar, sheets list, keyboard (organiser report)

Owns: `LunaWriterLibraryUI/LibraryRootViewController.swift`, `Groups/*`,
`Sheets/*`, `Environment.swift` (add a `DocumentCloseReporting`/root
callback only; E2 adds the read-along teardown seam later),
`LunaWriter/WriterSceneDelegate.swift`, `LunaWriter/WriterAppDelegate.swift`,
`LunaWriter/WriterWiring.swift`, `LunaWriter/Info.plist`,
`scripts/install_all_luna_apps.sh`.

Closes: organiser #1 (scene lifecycle flush + `applicationWillTerminate`), #3,
#4 (document types + import route), #7 (split display mode by real column
budget; explicit column widths; screenshot at 744/834/1024/1194/1366), #8
(sidebar selection persists, `clearsSelectionOnViewWillAppear` off when
expanded), #9/#10 (a "document closed" path that resets the secondary column
and flushes the outgoing editor), #11 (organiser `UIKeyCommand`s + a
`buildMenu(with:)` in the app delegate: ⌘N, ⇧⌘N, ⌘F, ⌥⌘N, ⌘,, ⌘⌫, ⌘E, ⌘↩,
⌘1/2/3), #18 (swipe providers on the list configuration), #19 (sheet context
menu), #20 (column title), #21 (reconfigure single row on `.document`), #22
(chips cap), #25–#29 (drop proposals, delete-group confirmation, cycle guard,
collapse handlers persisted in `WriterSettings`), #44 (install script).

Tests: extend `SheetsViewControllerTests` to obtain swipe actions THROUGH the
layout configuration (not by calling the methods); context menu returns the
expected actions; `GroupsViewControllerTests` collapse survives a reload; a
`LibraryRootViewController` test asserting the display mode at 744, 1024 and
1366 pt widths; key commands present on the root.

#### WP-B2 — Editor container, notes panel, settings, export, snapshots, goals (organiser report)

Owns: `LunaWriterLibraryUI/Editor/*`, `Settings/*`, `Export/*`. Hands off: the
read-along chrome constraint block in `EditorContainerViewController.swift:80-97`
and the chrome teardown belong to E2; do not touch them.

Closes: organiser #12 (all four action sheets → `UIMenu`s; add a test that
presents each entry point under a regular-width trait collection), #13
(presentation delegate + Done), #15 (container observes `.notes`/`.document`),
#16/#17, #23/#24 (goal units via `sentenceCount` and `wordCount / 250`;
"Remove goal" row), #30 (`keyboardLayoutGuide`), #31 (panel observes notes),
#33 (Settings entry: gear on the sidebar bar + ⌘,; form sheet on wide, push
on compact — B1 adds the key command, B2 exposes `WriterSettingsViewController
.present(from:)`), #34 (appearance row acts or goes), #35 (`snapshotCount`
from A2 — until merged, compute one aggregate query locally), #37 (sanitised
export filename), #38 (`@media print`), #39 (restore routes through the open
editor: add `replaceText(_:)` to `DocumentEditing`, `WriterEditorScreen`
forwards to the session — WP-C owns the session side and adds
`DocumentSession.replaceWholeText(_:)`; until merged, stub through
`flushPendingSave` + reload), #40, #42.

Tests: `EditorContainerViewControllerTests` for the notes-panel dismissal
state, for trash-closes-editor; `WriterSettingsViewControllerTests` for the
menu-based rows; `DocumentExporterTests` filename sanitising; a
`GoalEditor`/`SheetCell.progress` table for all four units.

#### WP-C — Editor (editor report)

Owns: everything under `LunaWriterEditor/`, `LunaWriter/WriterEditorScreen.swift`.

Closes, in this order: WriterTextView P1 ×3 (`hasStrings`; nil paste returns;
`documentLength` through the data source), MarkdownTextStorage P1 (apply the
model edit inside `replaceCharacters`; no coalescing arithmetic), P2 ×2
(`length` override + cached string; conditional `edited`), composer P2 ×3
(bounded first pass; `wantsViewport`; run-based merge), P3 unused API;
SyntaxColourLayer P2 ×2; SentenceGeometryProvider P1 (invalidate on relayout:
`viewDidLayoutSubviews`/`viewWillTransition` in `EditorViewController`, and a
new `EditorLayoutObserving` witness on `EditorViewController` with
`editorDidRelayout(_:)` and `editorDidScroll(_:)` that E2 will adopt), P2 ×2;
Focus P1 ×2 (keyboard-aware typewriter box; inset reset), P2 ×2
(`isComposing`; no scroll while dragging), P3; KeyboardFrameObserver P1
(screen-space conversion via one `keyboardOverlap(in:)`), P2 ×2 (local key;
`scrollViewDidScroll` re-places the overlay and notifies the observer);
Mention P2 ×2, P3; AI path: WIRE it (menu items gated on
`aiAssistant?.isAvailable`, key commands), fix the fixed-offset stream and the
stale range via revision guard, retain and cancel the task; DocumentSession P1
×2 (re-anchor authorship; `undoManager?.removeAllActions()` via the delegate
method the editor now implements), P2 orphan-on-edit kept, P2 async save
with revision guard, P3 explicit `close()`, plus `replaceWholeText(_:)` for
B2's snapshot restore; EditorViewController P2 ×5, P3 ×3 (undo grouping,
`addNoteAt` range); EditorAccessoryBar P2 (recompute from `didMoveToWindow` +
trait change), P3; AuthorshipSpanList P2; statistics P2 (background measure,
`.common` mode). Also wire `MarkdownEditingCommands.continueList`/`indent`/
`outdent` to Return and Tab (text report #35) — the commands themselves are
D's.

Tests: editor report "Test gaps" 1–9.

#### WP-D — Text and models (text report)

Owns: `LunaWriterText/*`, `LunaWriterModels/*` except `WriterDocument.swift`
(A2 adds `sentenceCount`) and the `SentenceLayout`/`WordLayout` move (F).

Closes: text #3 (CRLF chunk boundary), #6 (validate the delta; rebuild on
mismatch), #7 (`blockKind(at:)`, `blockLineRange(at:)` and use them), #8, #9,
#10 (document), #11 (fence indent), #12, #13 (comment), #14, #15 (`<br>`),
#16 (pipe paragraph), #17 (scheme filter), #18, #19, #20, #21 (suffix from
capped quote), #22, #23, #24, #25 (one model per summary; bounded heading
search), #26, #27, #28, #29 (stamped LRU), #30 (revision-keyed caches;
`WordSegmenter` cache), #31, #32, #33, #34, #36, #37 (delete
`marker(ofLine:)`); models #1 (one round-trip test), #2 (document the unit).
Keep `continueList`/`indent`/`outdent` — C wires them.

Tests: text report "Test gaps" 1–13.

#### WP-E1 — Gaze and voice (voice-gaze report, module-local items)

Owns: `LunaGaze/*`, `LunaWriterVoice/*`. Must keep the Reader's RSVP callers
compiling (`LunaReaderUI`, `LunaReaderEngine`).

Closes: voice #1 (restart the recognition request on final/error), #2 (drive
`tick()` from the tap callback, hop to main), #3 (forward `.end`), #4 (drop
`.duckOthers`), #5 (interruption/route/config-change observers), #6
(`@MainActor`), #7 (in-place RMS, `AVAudioTime` stamps), #8, #9, #10, #11, #13;
availability #12 (an `unasked` state; `resolve()` callable again); gaze #14
(screen size captured once, injectable), #15 (`@MainActor`), #16, #17
(`GazeFrame` via a second optional delegate method), #18 (ppi from
`nativeScale`), #19 (camera position parameter), #20 (the gate takes the
oriented size — expose `GazeGate.screenSize` semantics clearly; E2 sets it),
#21 (NaN guard), #22, #23 (windowed scoring + cached bounds, asserted within
epsilon), #24, #25, #26 (collector `startTime` set in `begin`; test with a
large clock offset), #28, #29 (reference rect), #30 (store API unchanged; E2
reads per orientation).

Tests: voice-gaze report "Test gaps": clock offset, landscape fixture,
non-finite input, availability re-resolve against a stub, session teardown
(the last is E2's).

#### WP-G — Tooling and docs (haiku)

Owns: `claudedocs/writer.md` (update after the waves land — the lead hands the
final list), `scripts/hide_generated_schemes.rb` check, `LunaWriter.xctestplan`
includes every `Writer*`/`ReadAlong*`/`Gaze*`/`Voice*` suite added by the
waves. Runs last; small.

### Wave 2 (after C, B2 and E1 merge)

#### WP-E2 — Read-along integration (read-along report + voice-gaze #31–#34)

Owns: `LunaWriterReadAlong/*`, `LunaWriter/WriterReadAlongWiring.swift`,
`LunaWriterLibraryUI/Environment.swift` (read-along seams only),
`EditorContainerViewController.swift` lines for the chrome block and teardown.

Closes: read-along #1 (marks through `ReadAlongTextHosting` →
`DocumentSession.add/removeAnnotation`; delete the mark half of
`ReadAlongMarkStore`), #2 (weak host; `ReadAlongChromeProviding.tearDown(for:)`
called from the container on close; weak session keys), #3 (layer ids; delete
the read-along `AnnotationLayer`), #4 (HUD overlaid top-trailing), #5, #6, #7,
#8 (adopt C's `EditorLayoutObserving` → `refreshLayout()`, `viewDidResize`,
`userDidScroll`), #9 (tick gating), #10 (orientation from the window scene;
reload calibration; gate size), #11 (screen coordinate space), #12, #13, #14,
#15, #16, #17, #18, #19, #20, #21, #22, #23, #24, #25 (wire
`AnnotationPresenter`: one per session, `readAlongMenu(for:)` into the
editor's menu, tap routing), #26, #27, #28 (one colour table in
`EditorTheme`), #29, #30, #31.

Tests: read-along report "Test gaps" 1–9.

#### WP-F — Mac seams (all reports' Mac sections)

Owns: `Package.swift` (new `LunaGazeCore` target or a `#if canImport(ARKit)`
split inside `LunaGaze`; `LunaWriterEditor` drops `LunaGaze`), the
`SentenceLayout`/`WordLayout` move to `LunaWriterModels` (with a re-export from
`LunaGaze`), `AuthorshipSpanList` move to `LunaWriterModels`,
`GazeTrackerMaking` witness (replaces the `ARFaceGazeTracker()` defaults),
`AccessoryBarPolicy`, `KeyboardMetricsProviding`, `GazeOrientation` plain
enum replacing `UIInterfaceOrientation` in `GazeCalibrationStore` /
`GazeScreenProjection` / `VisualAngle`, voice-only anchor at the caret in
`currentAnchor()`.

Acceptance: `xcodebuild build -scheme LunaWriter -destination
'platform=macOS,variant=Designed for iPad'` succeeds; `LunaTests` green;
the RSVP suites still pass (the `LunaGaze` product stays linked by the central
app, see `claudedocs/writer.md`).

## 5. Merge order and verification

1. Wave 1 merges in the order A2, A1, D, C, B1, B2, E1 (A2 first because A1
   and B2 depend on its schema additions; C before B1/B2 because both consume
   `DocumentEditing.replaceText` and the close path).
2. `scripts/run_tests.sh --fresh` after wave 1. Baseline before this work:
   2992/20/0 on 2026-08-11 plus the Writer suites landed since.
3. Wave 2 (E2, F) in worktrees off the updated `main`; merge E2 then F.
4. Full suite again; the iPad screenshot pass from §7 repeated on the merged
   build; the Mac "Designed for iPad" build; `claudedocs/writer.md` updated
   (WP-G).

## 6. Deliberately deferred

- Multi-scene support (`UIApplicationSupportsMultipleScenes`). The statics in
  `WriterWiring` and `OpenSessionRegistry` are compatible with it; nothing in
  this plan should add a new static that would block it.
- A `-LunaStage` catalog for the Writer (organiser #43). Useful, separate.
- Dynamic Type in the lists (organiser #41).
- Catalyst / native AppKit target. The seams in §3 are the enabling work.

## 7. Evidence

Screenshots of the Writer on the iPad Pro 13" and iPad mini simulators, both
orientations, before the changes, are recorded under
`writer-hardening/screenshots-before/` once the simulator build completes
(this section is appended by the lead).
