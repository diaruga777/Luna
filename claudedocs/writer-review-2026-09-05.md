# Luna Writer review — 2026-09-05

Scope: the everyday writing and note-capture path, its storage and indexing,
library/editor wiring, and test-only abstractions. Fixes are included in this
change; this is not a claim that every optional gaze/voice/AI feature was
exercised on hardware.

## Correctness findings addressed

- **P1 — ordinary edits could miss autosave.** `EditorViewController` kept an
  edit from `shouldChangeTextIn` but cleared it in `didChangeSelection` before
  `didChange` could consume it. UITextView callbacks are not a reliable edit
  log. `DocumentSession` now observes actual storage mutations, including undo.
- **P1 — a flush could return before adopting a queued save's result.** The
  session cleared dirty state as soon as work was queued. `saveNow` could wait
  for I/O but leave the old path/title in memory while the completion waited
  on main. Dirty state now reflects committed edits, and flushes consume the
  serial queue's result. Successive saves use the last written document, so
  renaming twice cannot leave a stale intermediate file behind.
- **P1 — autosave overwrote unrelated metadata.** Saving an editor's old
  document value could erase a favourite, goal or keyword change. The file
  store fetches current metadata and persists only text-derived columns.
- **P1 — note failures discarded drafts.** Return cleared the one-line field
  regardless of the insert result. Notes now save asynchronously, retain
  failed drafts, and expose a retry message. A derived embedding failure no
  longer reports that a committed note failed, avoiding duplicate retries.
- **P1 — an external file deletion could trash an unsaved document.** The
  reconciler only checked dirty state for modified files. Missing-file
  reconciliation now defers dirty documents too. Dirty state updates
  immediately rather than through the registry's 250 ms polling gap.
- **P1 — external-change reload existed only as an unconnected API.** The
  library adapter now observes real document changes and loads a newer file
  revision into an idle session, with an edit-revision check after the read.
- **P2 — Mark as mine did not persist unless another edit followed.** The
  action now marks the session dirty and persists the changed authorship.
- **P2 — existing ordinary notes could not be edited.** Tapping them now
  reopens their full text in the composer; saving updates the existing ID and
  search entry. Anchored notes retain their navigation and gain an edit menu.
- **P2 — stale related-note results could return after clearing the text.**
  Clearing the context now invalidates in-flight requests before publishing
  the empty result.
- **P2 — simulated AI streaming followed a moving caret.** The model API
  already returns a complete response. Retyping it with a timer could insert
  at a subsequently moved selection and complicate authorship and undo.
  Continue and rewrite now apply one attributed edit, protected by the
  existing cancellation and edit-revision checks. One undo restores a rewrite.
- **P2 — keyboard avoidance used custom geometry.** The editor and statistics
  bar now sit above UIKit's keyboard layout guide. Typewriter positioning uses
  the resized editor height instead of subtracting keyboard overlap again.

## Performance and simplification

- Replaced the formatting composer's boundary-by-contribution scans with
  Foundation attributed-string composition, retaining attribute precedence
  and clipping. A Debug simulator benchmark over the same 1,000 Markdown
  paragraphs improved from **1.939 seconds to 0.011 seconds** on average
  (three iterations each), roughly **175× faster for this operation**.
  This is not a whole-app or device-frame latency measurement.
- Large edits paint only the viewport and its slack. Scrolling and layout
  invalidate the visible formatting rather than waiting for scrolling to end.
- Removed the per-keystroke document delegate update that rebuilt header
  menus and read notes from SQLite; those updates belong to actual saves and
  library notifications. Note count refreshes follow note changes.
- Removed the duplicate document-index pass and disk read from text saves.
- Removed duplicate note attachment/index calls from the panel. SQLite note
  insertion already attaches atomically and maintains its FTS row.
- Moved note insert/update work, including embedding calculation, off main.
- Removed `AutosaveScheduling`, `AutosaveScheduled`, the manual test scheduler,
  and the registry polling timer. Tests exercise a real timer and real files.
- Removed `NoteRelevanceProviding`, its environment plumbing, fake and test:
  the shipping app never supplied it.
- Removed the XCTest-specific Markdown recovery branch. Debug users should
  get the same safe recovery that the tests exercise.
- Removed `StreamingTextInserter`, its timer and simulated-streaming tests;
  replacement tests exercise actual UIKit edits, authorship and undo.
- Removed `KeyboardFrameObserver`, `KeyboardMetricsProviding`, the unused
  Mac keyboard stub and the tests that only drove those abstractions.
- Retained the storage, editor and read-along interfaces that have actual
  production responsibilities. Removing those wholesale would be a larger
  dependency rewrite with little immediate benefit to writing.

## Verification

- Final Writer-focused run: **584 tests collected, 582 passed, 2 skipped,
  0 failures** across 53 test classes. Confirmed with the result bundle's
  summary, not just the shell wrapper. Coverage includes real UITextView
  editing/undo, session saves and retries, real-file reconciliation, notes,
  formatting, focus, mentions and library integration.
- `LunaWriter` builds and launches on an iPhone 17 Pro simulator with iOS
  26.2 using Xcode 26.2 and normal simulator signing.
- The full repository suite, run after the saving/notes fixes and before
  the final rendering/keyboard changes, collected **4,837 tests: 4,804 passed,
  24 skipped, 9 failed**. None of the failures were Writer tests. A clean-main
  baseline was not run, so this review does not establish when they arose.
  Failures were in `ArticleCardsExternalOpenTests`, `ArticleCoverThumbnailTests`,
  `CardPlaybackSpeedTests`, `ProductHistoryPillRenderTests`,
  `ScrollDirectionImmersionTrackerTests`, `ShareSurfaceDriverTests`,
  `UtilCardTests`, `WeeklySaveTests` and `XteinkPluginTests` (runner crash).
  The existing `scripts/run_tests.sh` reported the final retry as green;
  the result bundle correctly retains the earlier failures. That unrelated
  wrapper was not changed.
- Simulator gesture verification was blocked by nonfunctional input: the
  HID CLI reported no Legacy HID port, and MCP taps did not dismiss a system
  alert. Launch was observed, but no successful end-to-end gesture walkthrough
  is claimed. The UIKit-backed automated checks above did run successfully.

Local evidence: `/tmp/luna-writer-reviewed.xcresult`,
`/tmp/luna-writer-all-final.log`, `/tmp/luna-writer-render-after.log`, and
`/tmp/luna-writer-smoothness-full.log`. Temporary artifacts may be removed by
the system and are not checked into the repository.

## Remaining limits

- File content and SQLite metadata are separate resources. Atomic file
  replacement protects the bytes, but there is still no single transaction
  across a rename and the database commit. Crash recovery during that narrow
  boundary, external folder moves and two independent writers to the same
  file deserve a dedicated storage pass.
- Camera read-along, speech and on-device generation need device verification;
  the simulator cannot validate their hardware behaviour. The app retains
  existing Swift 6 isolation warnings while building in Swift 5 mode.
