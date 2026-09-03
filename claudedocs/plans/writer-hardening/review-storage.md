# Luna Writer review — `LunaWriterStorage` (2026-09-03)

Scope: every Swift file under `LunaLibraries/Sources/LunaWriterStorage/`, plus `LunaWriter/OpenSessionRegistry.swift`, `LunaWriter/WriterWiring.swift`, and the call sites in `LunaWriterLibraryUI` / `LunaWriterReadAlong` needed to confirm behaviour. Reviewer: Opus subagent, read-only. Severity: P0 crash/data loss, P1 wrong behaviour, P2 perf/leak, P3 simplification.

## Files/ExternalChangeReconciler.swift

### P0 — Trashing a sheet resurrects it as a duplicate on the next folder scan

`ExternalChangeReconciler.swift:75` builds `byPath` from `library.documents(matching: FilterPredicate(), scope: nil)`, and that query is `… WHERE trashed_at IS NULL` (`SQLiteWriterLibrary+Documents.swift:45`). Nothing in production ever calls `FileDocumentTextStore.deleteText` (the only caller is `LunaTests/LibraryFileLayoutTests.swift:156`). So `SheetsViewController.trashDocument` and `EditorContainerViewController.trashDocument` stamp `trashed_at` and leave the `.md` on disk. On the next scan the file is not in `byPath`, falls through line 84, and `adopt(file)` mints a brand-new `DocumentID` for it. The sheet is now in Trash *and* back in the library under a new id, with its notes, annotations, keywords, favourite and goal left on the trashed row.

Fix: `trash(_:)` must move the file out of the watched tree (a `.Trash` folder under the library root, excluded from `LibraryFolderWatcher.scan`), and `restore(_:)` must move it back.

### P0 — Empty Trash re-creates every sheet it just deleted

`SQLiteWriterLibrary+Documents.swift:255-260` deletes the rows; no file is touched. Every `.md` under the library root is then unknown to `byPath` and gets adopted as a new sheet on the next scan. `WriterDatabaseTests.testEmptyingTheTrashRemovesEverythingHangingOffTheSheet` passes because it never runs a scan. Fix: `emptyTrash` must unlink the files of the rows it deletes.

### P0 — Deleting a group brings the group and its sheets back

`SQLiteWriterLibrary.delete(_ id: GroupID)` (`SQLiteWriterLibrary.swift:116-137`) trashes the documents into the Inbox and deletes the group rows, but leaves both the folder and the files on disk. The next scan finds `Travel/Japan/Deep.md`, `groupForFolder` (`ExternalChangeReconciler.swift:171-192`) re-creates `Travel` and `Japan` as fresh groups, and `adopt` re-creates the sheets with new ids. Fix: `delete(_ id: GroupID)` must remove (or relocate) the folder subtree in the same operation.

### P1 — A file that comes back is adopted rather than restored

`reconcile` line 99-103 trashes a sheet whose file is missing (correct for iCloud eviction). When the file returns, line 84 no longer finds it in `byPath` (the row is trashed) and `adopt` makes a new sheet. Fix: before adopting, look for a trashed row with that exact `file_path` and `restore` it instead.

### P1 — Renaming a group folder in Files loses every sheet's metadata

Renaming `Library/Travel` to `Library/Trips` moves every file. The scan sees N missing paths (all trashed) and N unknown paths (all adopted). There is no identity on disk. Fix: match unmatched files to trashed-this-scan documents by content hash before adopting, and carry the row across.

### P1 — Non-ASCII paths can fail to match

`LibraryFolderWatcher.scan` (`Files/LibraryFolderWatcher.swift:114-117`) derives `relativePath` by stripping a prefix from `url.standardizedFileURL.path`, and `reconcile` compares it to `document.fileRelativePath` with `==`. Neither side is Unicode-normalised. Fix: normalise both sides with `precomposedStringWithCanonicalMapping` in `scan` and in `LibraryFileLayout.join`.

### P2 — A scan is not one transaction, and does 4 write round trips per adopted file

`adopt` (line 109-123) runs `createDocument`, `library.update`, and `documentIndex.index`, each its own transaction. Wrap one `reconcile` in a single `database.transaction`, or batch the adoptions.

### P2 — `reanchorMarks` read-modify-write is not atomic

Line 148-167 reads `marksStore.marks(for: id)` and writes `replaceMarks` in two separate transactions. Do both inside one `database.transaction`.

### P3 — `library.groups()` fetched twice per adopted folder chain; `group(forFolderPath:)` is cubic

`groupForFolder` calls `LibraryFileLayout.group(forFolderPath:groups:)` once at line 176 and once per depth at line 182; `folderPath` rebuilds a dictionary every time (`LibraryFileLayout.swift:44-46`). Build the maps once.

## Files/FileDocumentTextStore.swift

### P1 — A failed move deletes the destination sheet's file

`saveText` line 53-54: `try? fileManager.removeItem(at: targetURL)` then `try fileManager.moveItem(…)`. If the remove succeeds and the move throws, the destination file is gone and the row is not updated. Fix: write the new text to `targetURL` atomically first, then remove `previousURL`.

### P1 — A `.md` that is not valid UTF-8, or not yet downloaded, silently becomes an empty sheet

`loadText` line 32 returns `""` when the file is absent, and `adopt`/`reload` use `try? String(contentsOf:…, encoding: .utf8) ?? ""` (`ExternalChangeReconciler.swift:110,126`). A UTF-16 file or an iCloud placeholder reads as empty; `reload` writes zero counts and Untitled over a real sheet; a later save writes the empty string to disk. Fix: distinguish absent / undecodable / empty; try `String(contentsOf:usedEncoding:)` with fallbacks; on read failure skip the file; check `ubiquitousItemDownloadingStatusKey`.

### P1 — Two titles differing only by Unicode normalisation collide onto one file

`LibraryFileLayout.path` de-duplicates with `Set(taken.map { $0.lowercased() })` (`LibraryFileLayout.swift:64,67`) — case but not normalisation. Fix: fold with `precomposedStringWithCanonicalMapping().lowercased()` on both sides.

### P2 — Three `library.groups()` round trips per save

`saveText` line 45, 46 (`takenPaths`), and `takenPaths` line 76. Hoist one `let groups`.

### P2 — Only the write is file-coordinated; the move and the delete are not

`write` uses `NSFileCoordinator` (line 88-102); `removeItem`/`moveItem` on lines 53-54 and `deleteText` line 70 are raw. Coordinate the move.

### P3 — The suffix search gives up silently

`LibraryFileLayout.swift:67`: `while lowered.contains(…), suffix < 1_000`. Fall back to a short UUID suffix.

## Files/LibraryFolderWatcher.swift

### P1 — The watcher never fires for a file inside a group folder

`start()` opens a single `O_EVTONLY` descriptor on `rootDirectory` (line 58) and one `DispatchSource` (line 61-63). A vnode source reports events for that inode only. Every sheet lives at `Library/<Group>/…/<Title>.md`, so edits inside a group folder never fire. External adoption effectively only works for changes directly in `Library/`. Fix: watch every directory (re-walked after each scan), or `NSFilePresenter` with `presentedSubitemDidChange(at:)`, plus scan on `willEnterForeground` as a floor.

### P2 — `deinit` can deadlock on the watcher's own queue

`deinit { stop() }` (line 51) and `stop()` opens with `queue.sync` (line 72). If the last strong reference is a temporary made on the watcher queue, `deinit` runs on that queue and deadlocks. Make `stop()` the owner's job; no `sync` in `deinit`.

### P3 — `scanNow`'s doc comment contradicts its behaviour (line 81-85).

### P3 — A rename or delete of the root leaves a dead watcher

Mask includes `.rename`/`.delete` (line 62) but the handler only schedules a scan. Cancel and re-`start()` on those flags.

## Database/WriterDatabase.swift

### P1 — The prepared-statement cache is unbounded, and the SQL keys are per-result-set

`prepare` caches every distinct SQL string forever (`WriterDatabase.swift:141-155`). Hot paths interpolate ids into the SQL: `SQLiteWriterLibrary+Documents.swift:96-99` (keyword fetch `IN (…)`), `:49-50` (scope subtree), `SQLiteWriterLibrary+Notes.swift:147-149` (attachments), `SQLiteNoteIndex.swift:147-148` (scope uuid). Every distinct result set mints a permanently retained statement. Fix: bind the id list (`json_each` over a bound JSON array, or bucketed placeholders), and cap the cache with LRU eviction that finalises evicted statements.

### P2 — A failed ROLLBACK wedges the connection permanently

`transaction` (line 106-120) does `try? execute("ROLLBACK")`. Check `sqlite3_get_autocommit(handle)` afterwards and retry.

### P2 — `WriterSchema.migrate` stamps a version it did not reach

`Database/WriterSchema.swift:33-35`: after the loop, `if current > 0, current < schemaVersion { setUserVersion(schemaVersion) }`. Delete the branch.

### P2 — `retryingWhileBusy` sleeps the serial queue; the migration is not retried

`migrate` is called from `init` inside `queue.sync` (line 64-67) without `retryingWhileBusy`; a busy file at launch throws out of `makeDefault` and `WriterWiring.makeRootViewController` shows a blank placeholder.

### P3 — `userVersion` (line 188-190) deadlocks if called from inside a `perform`.

### P3 — `prepare` resets a cached handle mid-iteration if a `row:` closure re-runs the same SQL. Add a DEBUG in-flight assertion.

## Database/WriterSchema.swift

### P2 — No index for the reconciler's query shape: add `documents(file_path)` and a `document(atPath:)`.

### P3 — `authorship_spans.end` (line 161) is a keyword-shaped column name; rename to `end_offset`.

## Repositories/SQLiteWriterLibrary+Documents.swift

### P1 — `update(_ document:)` never refreshes the search index

`update` writes title/snippet/keywords/counts (lines 152-191) but not `documents_fts` or `document_embeddings`. `KeywordEditorViewController` edits keywords that never reach the index; `NoteRouter` cannot see them. Fix: make the index a collaborator of the library and re-index from `update`.

### P1 — `update(_ document:)` is a full-row write with no revision check

Every column is overwritten from the caller's copy, including `file_path` and `revision` (lines 156-176). Sheets list and editor hold separate copies; `LibraryChangeBroadcaster.post` hops through `DispatchQueue.main.async` (`WriterRepositories.swift:142`), so a stale favourite toggle can write back an old `file_path` → duplicate + trash. Fix: `UPDATE … WHERE id = ? AND revision <= ?`, or narrow writes (`setFavorite`, `setGoal`, `setKeywords`).

### P2 — Text search fetches everything then intersects in Swift with a hard 500 cap (lines 66-73). Join FTS in SQL.

### P2 — `WriterIntentServices.documents(matchingTitle:)` (`WriterIntentServices.swift:100-101`) is a full-library scan per keystroke. Push to SQL with `LIKE … COLLATE NOCASE LIMIT 20`.

### P3 — Duplicated `IN (…)` row-fan-in in `loadDocuments` (94-108) and `loadNotes` (`+Notes.swift:145-158`).

## Repositories/SQLiteWriterLibrary+Notes.swift

### P1 — A note's anchor silently re-points when the note is on more than one sheet

`update` line 59 and `bindNote` line 115 write `anchor_document_id` as `note.documentIDs.first`; `loadNotes` fills `documentIDs` with no `ORDER BY` (148-149). Fix: store the anchor's document explicitly on `WriterNote`; `ORDER BY document_id`.

### P1 — Editing a note's text leaves its embedding stale

`update` (48-70) writes `notes.text`; `note_embeddings` has no trigger. `ReadAlongMarkStore.swift:80` calls `notes.update` without `noteIndex.index`. Fix: re-index at that site, and make the index a collaborator of the store.

### P3 — `insert` attaches, then every caller attaches again (41-43; `WriterIntentServices.swift:46,64-69`; notes panel 126-127).

## Repositories/SQLiteWriterLibrary+Marks.swift

### P2 — Counting snapshots loads every snapshot's full text

`snapshots(for:)` selects `created_at, text` (line 121). `WriterSettingsViewController.swift:253` sums counts across every document. Add `snapshotCount(for:)` and a metadata-only list.

### P3 — `snapshots(for:)` sorts twice (query orders; `SnapshotsViewController.swift:46` sorts again).

## Notes/SQLiteNoteIndex.swift

### P1 — `rebuild()` destroys embeddings it cannot recreate

Lines 104-108: `DELETE FROM note_embeddings` then `guard embedding != nil else { return }`. Move the guard above the delete.

### P1 — `index()` silently does nothing when the note row is not yet written (116-128; same in `SQLiteDocumentIndex.swift:33`). Make the missing row an error or take the text as a parameter.

### P2 — `refreshFTS` is redundant; the triggers already keep `notes_fts` exact, and a mismatched external-content `'delete'` corrupts the index. Delete it.

### P2 — `rebuild()` runs one transaction per note (109-111). Batch.

### P2 — `search` interpolates the scope uuid (147-148). Bind it.

### P2 — `NLEmbedding.vector(for:)` called from multiple threads (64, 137, 189) with no documented thread-safety guarantee. Serialise behind one queue.

### P3 — `bm25()` evaluated twice per row (140, 150; `SQLiteDocumentIndex.swift:132,137`).

## Notes/SQLiteDocumentIndex.swift

### P2 — No `rebuild()`; a drifted contentless `documents_fts` has no repair path.

### P3 — `VectorBlob.decode` (`Notes/Scoring.swift:85`) binds unaligned memory to `Float`. Use `loadUnaligned`.

## WriterStorageStack.swift / WriterWiring.swift

### P1 — The reconciler blocks the watcher queue on `DispatchQueue.main.sync`, once per changed file

`reconcile` calls `openDocuments?.hasUnsavedEdits` (line 91) from the watcher queue; `OpenSessionRegistry.hasUnsavedEdits` routes through `MainActor.assumeIsolatedIfNeeded` = `DispatchQueue.main.sync` off main. Latent deadlock with `watcher.start()/stop()` `queue.sync` called from main. Fix: a lock-protected snapshot of unsaved ids the reconciler reads without hopping, or an async reconcile.

### P1 — macOS: `.documentDirectory` in `.userDomainMask` is the user's real `~/Documents`

`WriterStorageStack.makeDefault` (57-59). Under a non-sandboxed macOS build the watcher would adopt every `.md` in `~/Documents`. Tier is otherwise UIKit-free. Gate on `#if os(macOS)` / explicit chosen folder with security scope.

### P2 — `LibraryBootstrap` (line 15) ignores the Trash when deciding "no sheets"; a second Welcome triggers the duplication chain.

## WriterIntentServices.swift / WriterSettings.swift

### P2 — `WriterSettings.write` (97-104) posts `didChange` synchronously on the writer's thread. Post on main.

### P3 — `addNote` (line 68) re-fetches the document it was handed.

## What is solid

`WriterStatement` lifecycle (reset on every path, `SQLITE_TRANSIENT`), `transaction` rollback on throw, connection settings match the project standard, enum columns map unknown raw values to defaults, the relational shape and cascades are real and pinned, `notes_fts` triggers are correct, renumbering rewrites whole sibling lists, `NoteCaptureSplitter` never drops text, `HybridScorer`/`VectorBlob` guard non-finite values, `FTSQuery` quotes tokens, anchor re-anchoring is tested.

## Test gaps

1. Trash, then scan (pins P0 #1). 2. Empty Trash, then scan. 3. Delete a group, then scan. 4. File disappears and returns → same id. 5. Rename a group folder externally → ids/marks kept. 6. `update(_ document:)` then `searchDocuments` for a new keyword. 7. `notes.update` then `related(to:)`. 8. Two holders, one row (stale `file_path`). 9. Watcher `start()` + write into a group folder → `libraryDidScan`. 10. NFC/NFD title and path collisions. 11. Non-UTF-8 and zero-byte `.md`. 12. `saveText` whose move fails. 13. Concurrent `perform` from several queues. 14. `rebuild()` with no embedding model. 15. Statement-cache growth bounded.

Two narrating comments to remove: `Files/ExternalChangeReconciler.swift:128-130`, `Notes/SQLiteNoteIndex.swift:114-115`.
