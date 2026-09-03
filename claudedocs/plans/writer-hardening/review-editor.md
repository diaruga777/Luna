# Luna Writer review — `LunaWriterEditor` (2026-09-03)

Reviewer: Opus subagent, read-only. Every file in the module read in full; consumers checked where a seam's contract depends on them. Severity: P0 crash/data loss, P1 wrong behaviour, P2 perf/leak, P3 simplification.

## `Text/WriterTextView.swift`

### P1 — Reading `UIPasteboard.general.string` to build the edit menu raises the system paste prompt
`WriterTextView.swift:178`, `:206`, via `Authorship/PasteInterceptor.swift:35` and `WriterTextView.swift:21-29`. `hasText` reads `UIPasteboard.general.string` on every edit-menu build (every word selection / long press). Since iOS 16 a pasteboard read without a paste gesture shows the "would like to paste from" alert; "Don't Allow" then makes `hasText` false for the session.
**Fix:** add `hasStrings` to `PasteboardReading`; use it in `PasteInterceptor.hasText`. Keep the `.string` read inside `paste(_:)` / `pasteAsAIText(_:)`.

### P1 — A non-text paste falls through to `super.paste`, which puts an attachment character into a `.md` file
`WriterTextView.swift:151-157`. `pastedString` is nil for an image/file URL; `super.paste` inserts an `NSTextAttachment` (U+FFFC). `LayoutAttributeStyler.apply` (`:53-56`) wipes the attachment key so the glyph vanishes but the character stays, is saved to the `.md`, and is counted.
**Fix:** on nil `pastedString`, return without `super.paste`, or flatten `itemProviders` to text.

### P1 — `textView.textStorage` is read on a TextKit 2 text view
`Authorship/AuthorshipTracker.swift:66`. The module's rule (`WriterTextView.swift:46-51`) is never to touch a TextKit 1 accessor. Unverified whether it downgrades on the current SDK, but trivially avoidable.
**Fix:** pass `documentLength` through `WriterTextViewDataSource` from `session.storage.length`.

### P2 — `textColor` writes a foreground colour over the whole document at init (`:111`, `:113`). Set `typingAttributes` or nothing.

### P3 — `insert(_:as:)` (`:141-147`) asks the delegate for permission UIKit asks again; delete the manual call. `textDragInteraction?.isEnabled = true` (`:109`) restates the default.

## `Text/MarkdownTextStorage.swift`

### P1 — Coalescing two edits in one editing group feeds the line table a range that describes no real splice
`MarkdownTextStorage.swift:85-94`, consumed at `:110` by `MarkdownDocumentModel.apply(edit:replacementLength:)` → `LineTable.swift:44-77`. Two disjoint edits before `processEditing` widen to the union with a running delta: delete `[0,1)` then insert at 50 yields `apply(edit: [0,50), replacementLength: 1)`, claimed delta -49 vs real 0. `LineTable.apply` computes `newLength` wrong and `appendStarts` → `getCharacters(_:range:)` past the real length is an `NSRangeException`. Disjoint pairs from UIKit are unconfirmed; the mis-scan is certain, the crash latent.
**Fix:** apply the model edit inside `replaceCharacters` immediately after `backing.replaceCharacters`; let `processEditing` accumulate only the union of rescan ranges.

### P2 — `edited(.editedAttributes:)` is called from inside `processEditing` (`:116`), driving a re-entrant pass and two `super.processEditing()` rounds per keystroke. Only issue it when `rescanned` exceeds the edited range; verify with a counter.

### P2 — `string` (and therefore `length`) copies the whole document on every access (`:73`). Override `length` to `backing.length`; cache the `String`, cleared in `processEditing`; prefer `nsText` (`:150`) internally (`setText` at `:131`).

### P3 — `restyleAll()` (`:45-50`, `:135-143`) and `applySettings`'s `composer.invalidate(nil)` are redundant with each other.

## `Rendering/RenderingAttributeComposer.swift`

### P2 — The first pass composes and paints the entire document
`:103-110` with `EditorViewController.swift:410-420`: `renderingViewportRange` falls back to the whole document while `viewportRange` is nil at `viewDidLoad`. `composedRuns` allocates one attribute dictionary per character (`:129`) plus a dictionary compare per character (`:144`, `:157`). Clamp the fallback or defer the pass until the viewport exists.

### P2 — Steady-state cost is five viewports of per-character dictionaries per keystroke (`:112-117` slack = 2× each side; `:129-139`). Merge over run boundaries (O(contributions)) instead of O(characters); the tests' invariants hold by construction.

### P2 — `invalidate(nil)` discards a pending specific range (`:70-77`). Keep a separate `wantsViewport` flag.

### P3 — `layers`, `addLayer(_:before:)`, `layer(_:)` (`:35`, `:46-54`, `:62-64`) have no caller.

## `Rendering/Layers/SyntaxColourLayer.swift`

### P2 — A render pass issues tagging requests, and re-issues them for every paragraph on every keystroke (`:62-80`; `invalidateTags(in:)` `:48-60` drops every paragraph after the edit). Move requests out of `contributions`; key `tags` by paragraph content.

### P2 — Under continuous typing the revision guard (`:87`) means colours never land. Compare per-paragraph text/revision instead of document revision.

## `Geometry/SentenceGeometryProvider.swift`

### P1 — Nothing invalidates the geometry when the text re-wraps
`:78-95` — only `didRescan` invalidates. Rotation, Split View resize, font-size change (`EditorViewController.swift:209-221`), keyboard appearance re-wrap without a storage edit; `WriterTextView.layoutSubviews` (`:121-126`) moves the lines; cached rects (`:129`) keep old positions. Read-along draws its band from those rects. `ReadAlongCoordinator.refreshLayout()` / `viewDidResize(to:)` have no production caller.
**Fix:** add `viewDidLayoutSubviews` / `viewWillTransition(to:with:)` to `EditorViewController`; on width/inset change call `geometry.invalidate(nil)` and notify an `editorDidRelayout` witness that read-along adapts.

### P2 — Any invalidation re-segments the whole document (`:84`, `:100-113`). Splice `sentenceRanges` through the edit.

### P2 — `ensureLayout(for: documentRange)` (`:135-137`) lays out the whole document on every miss; `nearestSentence(toY:)` (`:61-75`) asks every word's rect (`:122-127`). Ensure layout for the sentence's own range; compute `words` lazily.

### P2 — The module imports `LunaGaze` for two value types (`:7`), pulling ARKit into the editor tier. See Mac section.

## `Focus/` and typewriter scrolling

### P1 — The typewriter line is computed against the full view height, ignoring the keyboard
`EditorViewController.swift:239-255`. `visibleHeight` is `textView.bounds.height`; nothing subtracts the keyboard. On iPhone landscape the caret parks behind the keyboard. Pass `bounds.height - adjustedContentInset.top - keyboardOverlap`.

### P1 — The typewriter bottom inset is never taken back (`:243-246`; `applySettings` `:209-221`). Reset `contentInset.bottom` when typewriter is off.

### P2 — Typewriter scrolling animates on every selection change (`FocusModeController.swift:69-71` ← `textViewDidChangeSelection` `:379-384`; `focus(on:)` `:199-204` scrolls twice). Skip while `isDragging || isDecelerating`; one scroll per navigation.

### P2 — `isKeyboardVisible` written from two disagreeing sources (`FocusModeController.swift:41-47`; `:386-388`; `:572-576`; `KeyboardFrameObserver.swift:35`). Rename to `isComposing`, drive from first-responder state.

### P3 — Focus range at document end belongs to the previous paragraph (`FocusModeController.swift:84`).

## `Mention/KeyboardFrameObserver.swift` and overlay placement

### P1 — The keyboard frame is in screen coordinates and is converted as if it were window coordinates
`KeyboardFrameObserver.swift:9`; `EditorViewController.swift:270-274` `view.convert(keyboard.frame, from: nil)` converts from window, not screen. Wrong in Split View, Slide Over, Stage Manager.
**Fix:** `view.window?.screen.coordinateSpace.convert(frame, to: view)`; one `keyboardOverlap(in:)` on the observer shared with the typewriter fix.

### P2 — Notifications from another app's keyboard are accepted (`:37-41`). Guard on `keyboardIsLocalUserInfoKey`.

### P2 — The overlay does not follow the text when it scrolls (`:269-275`; no `scrollViewDidScroll`). Implement it; also forward to read-along's `userDidScroll()`.

## `Mention/MentionController.swift`

### P2 — Note creation writes SQLite and the embedding index on main (`:263-286`). Move to `searchQueue`.

### P2 — A peek freezes the query while the text view stays editable (`:246-260`, `:131`, `:315-324`). Recompute the span at close or resign first responder.

### P3 — Duplicate delegate signal at mention end (`:295-303`).

## `Authorship/StreamingTextInserter.swift` and the AI path

### P1 — The FoundationModels feature has no caller
`EditorViewController.swift:644`, `:656` are reachable from nowhere (menu at `WriterTextView.swift:176-192`, `keyCommands` `:301-317`, `EditorAccessoryAction`). `StreamingTextInserter` is dead. Either add the two commands (gated on `aiAssistant?.isAvailable`) plus key commands, or delete the whole path.

### P1 — The stream inserts at a fixed offset (`StreamingTextInserter.swift:48-76`, `:86`). Track the caret after each chunk, or cancel on a preceding edit.

### P1 — `rewriteSelection` deletes a range captured before the await (`:656-670`; `continueWriting` `:644-653`). Capture the revision or resolve via `TextAnchor`.

### P2 — `Task` not retained or cancelled (`:648`, `:661`).

## `Session/DocumentSession.swift`

### P1 — An external change leaves the authorship spans pointing at the old text (`:228-233`; saved back at `:187-189`). Re-anchor or reset authorship.

### P1 — A programmatic whole-text replacement leaves the text view's undo stack pointing at gone text (`:229` → `setText`). `undoManager?.removeAllActions()` on the external-change path via `DocumentSessionDelegate.documentSessionDidReceiveExternalChange` (exists, unimplemented by the editor).

### P2 — An annotation orphaned by an edit is silently deleted (`:152-166`) while one orphaned on load is kept (`:132-149`). Move it to `orphanedAnnotations`.

### P2 — Every save is synchronous on main (`:182-193`): file write, `replaceMarks`, full `storage.string` copy, anchor make per annotation. Snapshot on main, write on a serial queue with a revision guard.

### P2 — Only the app delegate flushes; a backgrounded scene does not (`WriterAppDelegate.swift:13-14`). Flush from `sceneDidEnterBackground`. (Lead note: with the scene lifecycle the app-delegate hook is never called at all — see organiser/shell review #1.)

### P3 — `close()` runs file and database I/O from `deinit` (`EditorViewController.swift:103-106`). Give the editor an explicit `close()`.

## `EditorViewController.swift`

### P2 — The input accessory view is a fixed 80 pt even when both children are hidden (`:136-143`; `RelatedNoteStripView.swift:55`; `EditorAccessoryBar.swift:144-147`). Recompute height; `inputAccessoryView = nil` when empty.

### P2 — Six synchronous note reads per keystroke while the overlay is up (`:277-295`). Put what the row needs on `NoteHit`.

### P2 — `keyCommands` rebuilt per query and swallows Return conditionally (`:301-317`). Register unconditionally; gate in `canPerformAction`/`validate`.

### P2 — `pendingEdit` survives a rejected change (`:362`, `:367-371`). Clear at the top of `shouldChangeTextIn` and on selection change.

### P2 — `Int.max` as a whole-document sentinel (`AuthorshipTracker.swift:30`; `:438`). Make the range optional.

### P3 — `applySettings` (`:209-221`) double-invalidates. Multi-line Markdown commands produce one undo step per line (`:348-352`). `writerTextView(_:addNoteAt:)` (`:470-472`) ignores its range.

## `Accessory/EditorAccessoryBar.swift`

### P2 — The hardware-keyboard check runs once, from `init`, before a trait collection exists (`:77`, `:71-76`). With a Magic Keyboard already attached the bar never hides. Recompute from `didMoveToWindow` and a trait-change registration.

### P3 — `button.tag` (`:107`) set and never read.

## `Authorship/AuthorshipSpanList.swift`

### P2 — Normalising overlapping spans loses the tail of the span underneath (`:220-231`). Emit the trailing remainder. Only reachable via malformed persisted marks.

## `Accessory/StatisticsBarView.swift` + scheduling

### P2 — The whole document is copied and walked grapheme by grapheme every 300 ms while typing (`EditorViewController.swift:225-235` → `TextStatistics.swift:40-44`, `:69`). Background queue with revision guard, or incremental counts; add the timer to `.common` mode.

## iPad, screen sizes, orientation

Handled well: `EditorMetrics.maximumColumnWidth` via `LunaLayout.readableWidth` and `textContainerInset(forContainerWidth:)` (`EditorMetrics.swift:62-83`); no `UIScreen`; `contentInsetAdjustmentBehavior = .always`.
Open: keyboard frame conversion (above); non-local keyboard notifications; no `viewDidLayoutSubviews`/`viewWillTransition` (geometry, read-along, overlay go stale); scroll position not preserved across rotation (P3: pin the visible character range); accessory bar hardware-keyboard hide never fires; ⌘S/⌘N absent (P3); no pointer treatment (P3); `NotePeekCardView` width cap baked at creation (`:496-498`, P3).

## Mac portability

1. **`import LunaGaze` in `SentenceGeometryProvider.swift:7` for `SentenceLayout`/`WordLayout`** (`GazeTextGeometry.swift:14,39`); `LunaGaze` imports ARKit unguarded. Move the two types to `LunaWriterModels`; `LunaGaze` re-exports; the editor drops the dependency.
2. **Idiom branching in `EditorAccessoryBar.updateHardwareKeyboardVisibility` (`:145`).** Replace with an `AccessoryBarPolicy` witness installed by the root; Mac answers false; iOS keeps a width + hardware-keyboard rule.
3. **Keyboard-frame notifications never fire on Mac.** The `isComposing` rename fixes Focus; give `KeyboardFrameObserver` a `KeyboardMetricsProviding` face whose Mac witness reports `.zero`.
Also: `hasStrings` fix makes the menu behave the same; give the `buildMenu` items `UIKeyCommand`-backed `UICommand`s so the Mac menu shows shortcuts; `FoundationModelsWritingAssistant` is already portable; `GCKeyboard.coalesced` is always non-nil on Catalyst.

## What is solid
Two-channel split (`LayoutAttributeStyler` writes only font/paragraph style; colour via layers; precedence pinned by tests). `POSTaggingService` (copy on caller thread, cancellable, deduped, bounded LRU, revision token). `AuthorshipSpanList` pure with a real suite. `TypewriterScroller`/`EditorMetrics` pure geometry. Retain-cycle hygiene: every delegate/observer weak, `NSHashTable.weakObjects`, timers `[weak self]` and invalidated. `MentionController`'s generation + query re-check. `PassthroughView` hit-test.

## Test gaps
1. `MarkdownTextStorage` has no suite (coalescing crash path). 2. `StreamingTextInserter` untested. 3. Paste path untested (`PasteboardReading` unused). 4. `RenderingAttributeComposerTests` never exercises `applyNow` (`layoutManager: nil`). 5. No keyboard coordinate-conversion test. 6. No re-wrap test for `SentenceGeometryProvider`. 7. `DocumentSession`: no authorship-after-external-change test; no edit-orphaned annotation test. 8. No test of the typewriter caller's visible box. 9. No test asserts `textLayoutManager != nil` after the authorship data-source path.
