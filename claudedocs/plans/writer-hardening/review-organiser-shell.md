# Luna Writer review — `LunaWriterLibraryUI` + `LunaWriter/` app shell (2026-09-03)

Reviewer: lead (full read of every file in the organiser tier and the app target). Severity: P0 crash/data loss, P1 wrong behaviour, P2 perf/leak/UX, P3 simplification.

## `LunaWriter/WriterAppDelegate.swift` / `WriterSceneDelegate.swift`

### 1. Unsaved edits are never flushed on background — P0 (data loss)
`WriterAppDelegate.applicationDidEnterBackground` (`:13-15`) calls `WriterWiring.applicationDidEnterBackground()` → `openSessions.flushAll()`. The app uses the scene lifecycle (`UIApplicationSceneManifest` in `Info.plist`, `WriterSceneDelegate`). UIKit does NOT call `applicationDidEnterBackground` on the app delegate when an app adopts scenes; it calls `sceneDidEnterBackground` on the scene delegate. `WriterSceneDelegate` implements neither `sceneDidEnterBackground` nor `sceneWillResignActive`. Compare `Luna/SceneDelegate.swift:298`, which does implement `sceneDidEnterBackground`. The autosave timer (`AutosaveScheduling`, 1 s debounce) is the only thing that saves; a swipe-to-home within that second, or a suspension that stops the run loop before the timer fires, loses the last edit. Nothing handles `applicationWillTerminate` either.
**Fix:** implement `sceneDidEnterBackground` (and `sceneWillResignActive`) in `WriterSceneDelegate` calling `WriterWiring.applicationDidEnterBackground()`; keep the app-delegate hook only if a test relies on it. Add `applicationWillTerminate` → same flush.

### 2. `MainActor.assumeIsolatedIfNeeded` uses `DispatchQueue.main.sync` — P1 (latent deadlock)
`WriterWiring.swift:122-129`. Used by `intentServices()` and `OpenSessionRegistry.hasUnsavedEdits` (`OpenSessionRegistry.swift:21-25`), which the reconciler calls from the watcher queue while `WriterWiring.storageStack()` calls `watcher.start()` (a `queue.sync`) from main. See storage review "reconciler blocks the watcher queue". Replace with an async hop or a lock-protected snapshot.

### 3. `show(document:)` for a deleted id parks `pendingDocument` forever — P3
`WriterWiring.swift:84-90`: when `root` exists but the document lookup fails, the id is stored as pending and re-attempted only by the next `makeRootViewController`. Distinguish "no root yet" from "no such document".

### 4. No document type declaration — P2 (feature)
`Info.plist` has `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` but no `CFBundleDocumentTypes`/`UTImportedTypeDeclarations` for `net.daringfireball.markdown` / `public.plain-text`, so Files' "Open in Luna Writer" and drag-onto-Dock on Mac are unavailable. Add the document type and route `scene(_:openURLContexts:)` file URLs to an "import into Inbox" path.

### 5. Single-scene only — P3 (iPad/Mac)
`UIApplicationSupportsMultipleScenes` is false. Two sheets side by side on iPad, or a second window on Mac, is impossible. Not required now; the registry and wiring are already static so multi-scene is a later step. Note in plan as deferred.

## `LunaWriter/WriterEditorScreen.swift`

### 6. `UnavailableEditorScreen` label has no trailing constraint — P3 (`:101-105`). Add `trailingAnchor <= -24`.

## `LibraryRootViewController.swift`

### 7. Triple-column forced on every "wide" container starves the editor — P1 (iPad portrait)
`updatePreferredDisplayMode` (`:52-58`) picks `.twoBesideSecondary` whenever `LunaLayout.isWide` (≥ 700 pt). On an iPad in portrait (744–1032 pt) that leaves the secondary column roughly 180–400 pt after two ~320 pt side columns, which is narrower than an iPhone for the editor. Ulysses shows three columns only in landscape on large iPads. `LunaLayout.wideThreshold` was designed for the card decks, not a triple-column organiser.
**Fix:** choose `.twoBesideSecondary` only when `width >= 320 + 320 + minimumEditorWidth (≈ 560)`, i.e. ≥ ~1180 pt (13" landscape), `.oneBesideSecondary` between 700 and that, and let compact collapse. Set `preferredPrimaryColumnWidth`/`preferredSupplementaryColumnWidth` (or fractions) and `minimumSecondaryColumnWidth` explicitly. Verify with screenshots at 744, 834, 1024, 1194, 1366 pt. (Screenshot evidence to be attached from the iPad simulator build.)

### 8. Sidebar has no persistent selection, and `clearsSelectionOnViewWillAppear` is left on — P2 (iPad)
`GroupsViewController` never selects `.libraryAll` on load and `applySnapshots()` rebuilds the section snapshots on every change, so the sidebar shows no selected row on iPad while `SheetsViewController` is showing a scope. Select the current row after each `reload()`; set `clearsSelectionOnViewWillAppear = false` on both list controllers when not collapsed.

### 9. Trashing the open sheet on a wide layout leaves it on screen — P2
`EditorContainerViewController.trashDocument` (`:237-241`) calls `backTapped`, which pops only when the nav stack has > 1 controller. In the expanded split view the editor is the secondary column root, so the trashed sheet stays open and its next autosave writes to a trashed row. Also `LibraryRootViewController.hasOpenDocument` is never reset. Add a `SheetsSelectionDelegate`/container-to-root callback "document closed" that resets the secondary column to the placeholder and `hasOpenDocument = false`. Same path should be taken when the reconciler trashes the open sheet or the sheets list trashes it.

### 10. Selecting a sheet always builds a brand-new `EditorContainerViewController` — P2
`show(document:)` (`:91-96`) replaces the secondary column each time. The old container's `DocumentSession` is released without an explicit flush (relies on `deinit`/timer; see editor review), and with the read-along leak (read-along review #2) nothing is released at all. Flush the outgoing editor explicitly (`editor.flushPendingSave()`) before replacing, and short-circuit when the same document is re-selected.

### 11. No hardware-keyboard commands at the organiser level — P1 (iPad/Mac)
The only `UIKeyCommand`s are in `EditorViewController` (bold/italic/link/focus + mention navigation). Nothing for ⌘N new sheet, ⇧⌘N new group, ⌘F search, ⌥⌘N notes panel, ⌘, settings, ⌘⌫ trash, ⌘E export, ⌘↩ open selection, ⌘1/2/3 column focus. Add them on `LibraryRootViewController` (so they work in every column) and, for Mac, a `buildMenu(with:)` override in the app delegate that places the same actions under File/Edit/View.

## `EditorContainerViewController.swift`

### 12. Action sheet presented with no popover anchor — P0 (iPad crash)
`presentExportOptions` (`:176-191`) presents a `UIAlertController(.actionSheet)` from a `UIMenu` action with no `popoverPresentationController.sourceView`/`sourceItem`. On iPad (regular width) UIKit throws `UIPopoverPresentationController should have a non-nil sourceView or barButtonItem set before the presentation occurs` — a hard crash. Same in `WriterSettingsViewController` `presentFontMenu`/`presentLineWidthMenu`/`presentFocusModeMenu` (`:175`, `:187`, `:199`).
**Fix:** replace the four action sheets with `UIMenu` submenus (export formats as a submenu of the ⋯ menu; settings rows as `UIButton` with `showsMenuAsPrimaryAction` or a `UIMenu` on the cell), or set `sourceItem` to the tapped control. Add a `LunaTests` check that no `.actionSheet` in the Writer modules is presented without an anchor (grep pin, or a test that presents each on a regular-width trait collection).

### 13. Swiping the presented notes sheet away leaves `notesPanel` stale — P2
`presentNotesPanel` (`:267-275`) presents `UINavigationController(rootViewController: panel)` on compact; interactive dismissal never clears `notesPanel`, so the next notes-button tap calls `dismissNotesPanel` on a gone controller and the user must tap twice. Set `presentationController?.delegate` and clear in `presentationControllerDidDismiss`; give the sheet a Done button.

### 14. Read-along chrome constraints (leading + trailing + fixed width) are unsatisfiable — P1
`:84-88` vs `ReadAlongHUDView.swift:79-80`. See read-along review #4. Overlay the HUD top-trailing; do not use it as the editor's top anchor.

### 15. Notes button count re-queries SQLite on every document update — P3
`updateNotesButton` (`:128-131`) runs on every `editor(_:didUpdate:)` (each autosave). Cheap, but it should be driven by `.notes` `LibraryChange` instead; the container observes nothing today, so a note added via "@" or an intent does not update the count. Make the container a `LibraryChangeObserving` for `.notes(document.id)` and `.document(document.id)` (title/favourite changed elsewhere).

### 16. Statistics via alert reads the whole file — P3 (`:193-208`). Acceptable; note the editor already has a statistics bar/sheet, so this duplicates `StatisticsSheet`. Pick one.

### 17. `menuTapped` is an empty `@objc` stub (`:133`) — P3. Remove; the button uses `showsMenuAsPrimaryAction`.

## `SheetsViewController.swift`

### 18. Swipe actions are declared on the wrong delegate and never fire — P1
`collectionView(_:leadingSwipeActionsConfigurationForItemAt:)` and `…trailing…` (`:300-312`) are plain methods, not `override`s; there is no such method on `UICollectionViewDelegate`. For a compositional list layout swipe actions come only from `UICollectionLayoutListConfiguration.leading/trailingSwipeActionsConfigurationProvider`, and `init` sets `trailingSwipeActionsConfigurationProvider = nil` (`:57`). Favourite, Move, Trash and Restore by swipe never appear; tests pass because they call the methods directly. Combined with #19 there is no way to trash, move or favourite a sheet from the list except Edit mode.
**Fix:** build the layout in `viewDidLoad` (or lazily) with providers capturing `[weak self]` that call the existing `leadingSwipeActions(for:)`/`trailingSwipeActions(for:)`.

### 19. No context menu on sheets — P1 (iPad pointer / Mac right-click)
Only groups have `contextMenuConfigurationForItemsAt`. Add one for `.document` rows: Open, Favourite, Move…, Keywords…, Goal…, Duplicate, Trash / Restore.

### 20. Column title is blank for a group or filter — P2
`title(for:)` (`:87-96`) returns `""` for `.group`/`.filter`. Look up the group/filter name from the library.

### 21. `reload()` on every `.document` change re-queries and re-sorts the whole list — P2
`libraryDidChange` (`:462-469`) reloads on `.document(id)` (every autosave of the open sheet). Fine for hundreds of sheets, but it also re-sorts and, with `.modifiedDescending`, the row jumps to the top while typing. Consider updating the single row's snapshot item (`reconfigureItems`) and re-sorting only on a debounce.

### 22. Keyword chips overflow the cell — P3
`SheetCell.chipsStack` (`:51-53`, `:96-102`) is a horizontal stack with no wrapping or clipping; many keywords extend past the trailing edge. Cap to N chips plus "+k", or `clipsToBounds`.

### 23. Goal progress for `.sentences` / `.readingMinutes` uses the word count — P1
`SheetCell.progress` (`:107-121`): `case .sentences, .readingMinutes: count = document.wordCount`. A 30-sentence goal compares words to 30; a 5-minute goal compares words to 5. `WriterDocument` carries no `sentenceCount`. Either store `sentenceCount` alongside `wordCount` in `WriterDocument` (computed by `TextStatistics` on save) and compute reading minutes as `wordCount / 250`, or drop the two units.

### 24. `GoalEditorViewController.clearGoal()` has no UI — P2
`:110-115` is public and called from nowhere but tests. Add a "Remove goal" destructive button/row.

### 25. Manual reorder ignores the destination section — P3
`performDropWith` (`:440-448`) uses `destination.item` even when the destination is the unattached-notes section.

### 26. No confirmation for `deleteGroup` — P2 (`GroupsViewController.swift:391-396`). The action is `.destructive` but immediate. Confirm with an alert naming the sheet count, as Ulysses does.

### 27. Collapsing a group via the disclosure control is undone by the next reload — P2
`GroupsViewController.collapsedGroups` (`:202`) is updated only by `toggleExpansion`, which UIKit does not call — the outline disclosure accessory mutates the section snapshot directly. Any `.groups`/`.notes` change re-applies `appendGroupTree` with the stale set and re-expands the group. Set `dataSource.sectionSnapshotHandlers.willCollapseItem/willExpandItem` to update `collapsedGroups`; persist it in `WriterSettings`.

### 28. Group drag onto a descendant — P2 (verify)
`performDropWith` (`:433-454`) calls `moveGroup(groupID, toParent: targetGroup)` with no ancestry check. If `SQLiteWriterLibrary.moveGroup` does not reject a cycle, the group tree becomes unreachable. Verify and guard in the UI too.

### 29. `dropSessionDidUpdate` always proposes `.move` (`:426-431`) even over fixed rows and for a group dropped on itself. Return `.forbidden` where `performDropWith` would no-op.

## `DocumentNotesPanelViewController.swift`

### 30. Compose bar is pinned to the safe area, not the keyboard — P1
`:82` pins `composeBar.bottomAnchor` to `safeAreaLayoutGuide.bottomAnchor`. The software keyboard covers the field on iPhone (sheet) and on iPad without a hardware keyboard. Pin to `view.keyboardLayoutGuide.topAnchor`.

### 31. The panel observes no library changes — P2
A note added via "@" mention, voice, or an intent while the panel is open is not shown until the panel is reopened. Adopt `LibraryChangeObserving` for `.notes(document.id)`.

### 32. Orphan detection resolves every anchor on every reload, on main — P3 (`:105-116`). Acceptable today; note it.

## `WriterSettingsViewController.swift`

### 33. The Settings screen is unreachable — P1
No production code constructs `WriterSettingsViewController` (only `LunaTests/WriterSettingsViewControllerTests.swift`). Font, size, line width, focus mode, syntax colouring, typewriter, authorship, gaze/voice toggles, calibration and appearance are all unreachable from the UI. Add a gear button to the groups sidebar's navigation bar (and ⌘,), presenting it as a form sheet on wide and a push on compact.

### 34. Appearance row does nothing on tap — P2 (`:98-114`, `:259-263`). Either present the shared appearance picker the other apps use or drop the row.

### 35. `totalSnapshotCount()` loads every snapshot's full text for every sheet on every `reloadData` — P2 (`:250-255`, also `settingsDidChange` → `reloadData`). Add `snapshotCount(for:)`/one aggregate `COUNT(*)` (storage review).

### 36. Cells are built fresh with `reuseIdentifier: nil` on every reload — P3. Fine for this table size; leave.

## `DocumentExporter.swift`

### 37. Export filename is the raw title — P2
`exportAndPresent` (`:131-134`) appends `document.title` as a path component; a title with `/` or `:` fails the write and the function returns silently (`:135-139`). Sanitise with the same rule `LibraryFileLayout` uses, and surface the failure.

### 38. PDF export carries the night stylesheet — P3 (design). A printed PDF with a `#0b0b0f` background is a deliberate choice worth confirming; a `@media print` override to paper colours costs one line.

## `SnapshotsViewController.swift`

### 39. Restore writes the file behind the open editor — P1 (data loss)
`restore(_:)` (`:94-100`) writes through `textStore.saveText` while `EditorContainerViewController` still holds a live `DocumentSession` with the pre-restore text. The editor keeps showing the old text and its next autosave overwrites the restore (and `DocumentSession.document.revision` is now stale). Route restore through the open session (`DocumentEditing.replaceText(_:)`), or close the editor before restoring and reopen after.

### 40. `snapshots(for:)` result is re-sorted (`:46`) though the query already orders — P3.

## Cross-cutting

### 41. Table/collection cells use fixed point sizes (`SheetCell` 16/13/12/11 pt, notes panel default) — P3. The rest of Luna uses fixed sizes too; consistent, but the writing app is where Dynamic Type matters most. Optional: `UIFontMetrics` scaling on the sheets list and notes panel.

### 42. `GroupIconPickerViewController` fixes 5 items per row (`:31`) — P3. On a 13" iPad form sheet that is fine; full-screen on iPad or Mac they become 200 pt cells. Use an adaptive count from the environment's container width.

### 43. No `-LunaStage` catalog for the Writer — P3 (tooling). `Luna/Stage/` has no Writer entries and the Writer has its own AppDelegate, so screens cannot be launched by argument for review. Consider a minimal `WriterStageCatalog` (empty library, populated library, open sheet, notes panel, settings).

### 44. `scripts/install_all_luna_apps.sh` does not install the Writer — P3 (tooling). `AllLunaApps.xcscheme` builds it (`:88-89`) but the install loop does not name it.

## Mac portability (organiser + shell)

What already works under "Designed for iPad" on Apple silicon: the split view, diffable lists, sidebar appearance, context menus, drag and drop, `UIMenu`s, App Intents. What needs work before Catalyst or a native Mac target:
- `NavHeaderBar`-based custom headers hide the navigation bar (`EditorContainerViewController:44-54`); on Mac a real `navigationItem`/toolbar integrates with the window title bar. Keep the header behind a small `EditorHeaderProviding` seam or accept the custom look.
- Keyboard commands and `buildMenu(with:)` (#11) are the biggest gap; a Mac app with no File menu is unusable.
- Popover anchors (#12), hover/pointer (`UIPointerInteraction` on chips/buttons — optional), right-click context menus on sheets (#19).
- `UIScreen.main` / `UIDevice.current.userInterfaceIdiom` appear only in `LunaGaze`/`LunaWriterReadAlong` (covered in those reviews); the organiser is clean.
- `WriterStorageStack.makeDefault` Documents-directory assumption (storage review).
- Multi-window (#5) is expected on Mac; keep deferred but do not add new statics that would block it.
