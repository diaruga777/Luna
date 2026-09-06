# Luna Writer — polish pass (2026-09-07)

Review of `LunaWriter` for correctness and feel, and the work it produced.
Goal from the owner: an extremely polished, snappy experience; the app
reopens instantly to the last page, with the keyboard where it was; UX
stays clean and minimal.

## Review findings

Read: `LunaWriter/*`, `LibraryRootViewController`, `EditorContainerViewController`,
`SheetsViewController`, `GroupsViewController`, `EditorViewController`,
`DocumentSession`, `WriterTextView`, `RenderingAttributeComposer`,
`WriterSettings`, `WriterStorageStack`, `LibraryFolderWatcher`, `Info.plist`.

### Launch and restoration

1. **No state restoration exists.** Every launch lands on the Groups
   sidebar (phone) or the empty "select a document" placeholder (iPad). The
   only persisted UI state is `GroupCollapseStore`. Nothing records the open
   sheet, the sidebar scope, the caret or whether the keyboard was up.
2. **Launch flashes the system colour.** `Info.plist` has `UILaunchScreen`
   as an empty dict, so the launch image takes the device's light/dark
   background. The app pins `.dark` and paints true black, so a light-mode
   device flashes white, then cuts to black. `Luna/Assets.xcassets/
   WriterLaunchBackground.colorset` (black) exists and nothing references it.
3. **`NLEmbedding.sentenceEmbedding(for:)` loads on the main thread during
   launch** (`WriterStorageStack.makeDefault` default argument), before the
   window exists. It is needed only for note ranking and the "@" overlay.
4. **First run opens on nothing.** `LibraryBootstrap` creates the Welcome
   sheet and `WriterWiring.install` throws the returned document away.

### Editor

5. **Header controls rebuild on every autosave.** `EditorContainerViewController
   .editor(_:didUpdate:)` fires one second after each keystroke burst and calls
   `setTrailingControls(trailingHeaderControls())`, which allocates a new ⋯
   button and menu each time. The title is reassigned even when unchanged.
6. **Every scroll frame repaints the viewport.** `scrollViewDidScroll` calls
   `composer.invalidate(nil)`, which composes five layers over ~3 screens of
   text and writes rendering attributes on the next turn, at up to 120 Hz.
   Since the composer installs `renderingAttributesValidator` (2026-09-05),
   a newly laid-out fragment is painted as it appears, so the per-scroll
   pass is redundant on a document whose layers did not change.
7. **Keyboard on open** only when the sheet is empty (`viewDidAppear`). A
   restored sheet must instead honour the saved first-responder state.

### Organiser

8. **The sheets list never shows which sheet is open.** `didSelectItemAt`
   deselects immediately, so on iPad's two- and three-column layouts the
   open sheet has no highlight, unlike the sidebar (which keeps
   `selectedRow` and reselects after every snapshot).
9. `sceneWillResignActive` and `sceneDidEnterBackground` both flush;
   harmless (the session's dirty guard) but the app-delegate
   `applicationDidEnterBackground` hook is dead under the scene lifecycle.

### Code quality

10. `DocumentSession.unsavedChangesDidChange` is a stored closure set from
    `OpenSessionRegistry.register`. The owner standard (CLAUDE.md, "Wiring
    is protocol contracts, never stored closures") wants a protocol witness.

Verified fine and left alone: autosave revision guard and synchronous flush,
external-change reconciliation guards, collapsed-stack push logic and its
`whenPrimaryStackSettles`, the notes panel re-hosting, the compact-width
`SheetsViewController.reload()` guard, Focus mode, mention overlay placement.

## Work packages

Each package is one agent in its own worktree branched from `writer-polish`.
Commit small, compile with the `LunaWriter` scheme after each change, run the
named test classes through the `Luna` scheme (the test host). No background
`xcodebuild`; one foreground build at a time per agent.

### WP-A — Restore the last page (Opus)

Persist and restore the open sheet, the sidebar scope, the caret and the
keyboard.

- `LunaWriterStorage/WriterSessionState.swift` (new): `WriterSessionState`
  over `UserDefaults` with `struct Snapshot: Equatable { documentID:
  DocumentID?; selection: LibrarySelectionValue; caretLocation: Int?;
  keyboardVisible: Bool }`. `LibrarySelection` lives in `LunaWriterLibraryUI`
  (it must stay there); the storage tier stores a small `Codable` mirror or
  a string encoding the organiser tier converts. Keys under
  `luna.writer.session.*`. Writes are cheap; write on every change.
- `LibraryEnvironment` gains `sessionState: WriterSessionState`.
- `DocumentEditing` gains `var editingState: EditorEditingState { get }`
  (`caretLocation`, `isKeyboardVisible`) and `func restoreEditingState(_:)`;
  `DocumentEditingDelegate` gains `editorEditingStateDidChange(_:)`. The
  `LunaWriterEditor` side: `EditorViewController` reports first-responder
  begin/end and caret moves (debounced to the caret's resting position, not
  per keystroke — the autosave timer is a fine cue) and restores: clamp the
  caret to the text length, `selectedRange`, `scrollRangeToVisible`, then
  `becomeFirstResponder()` in `viewDidAppear` when `keyboardVisible` was
  true. Keep the existing "empty sheet gets the keyboard" rule as the
  default when no state is saved.
- `LibraryRootViewController`: a `restore(_ snapshot:)` called from `viewDidLoad`
  (or right after by `WriterWiring`) that applies the sidebar scope to
  `groupsViewController`/`sheetsViewController` and opens the sheet **with no
  animation** and the full stack set at once. Collapsed: `primaryNavigation
  .setViewControllers([groups, sheets, editor], animated: false)`. Expanded:
  set the secondary column. A missing or trashed document restores just the
  scope. Record on every `show(document:)`, `documentDidClose`, sidebar
  selection and editing-state change; `WriterWiring.applicationDidEnterBackground`
  also writes the current snapshot as a belt-and-braces.
- First run: when `bootstrap()` returns the Welcome sheet and no snapshot
  exists, open it (the same restore path).
- Sheets list keeps the open sheet highlighted on a wide layout: track
  `openDocumentID`, reselect after `reload()`/`apply` completes, deselect only
  when collapsed (mirror `GroupsViewController.viewWillAppear`).
- Tests (`LunaTests`): `WriterSessionStateTests` round trip and defaults;
  `LibraryRootViewControllerTests`: restoring a collapsed root yields the
  three-deep stack with no transition pending and the sheets list on the
  right scope; restoring an expanded root sets the secondary column; a
  trashed id restores the scope only; `SheetsViewControllerTests`: the open
  sheet stays selected across a reload; an `EditorViewController` test that
  a restored caret and keyboard flag land (window-hosted).

### WP-B — Launch snappiness and small quality items (Sonnet)

- `Info.plist`: `UILaunchScreen` → `{ UIColorName: WriterLaunchBackground }`.
  Confirm the Writer target's Resources phase compiles `Luna/Assets.xcassets`
  (it holds `AppIconWriter`, so it should) and that the colour matches
  `LunaColors.background` in night mode.
- `NLSentenceEmbedding`: make the `NLEmbedding` load lazy, on the embedding's
  own queue, so `makeDefault` returns without touching NaturalLanguage.
  `modelVersion` is bound into the index tables, so it must still resolve to
  the same string; compute it on first use. Keep the failable init semantics
  the two indexes rely on (if a language has no model the index must still
  behave as "no embedding"). Test: `WriterNoteIndexTests` still pass; add a
  test that constructing the stack does not call into the model (a counting
  fake is enough).
- `EditorViewController.scrollViewDidScroll`: drop `composer.invalidate(nil)`
  if `RenderingAttributeComposerTests` plus a UI-driver screenshot after a
  scroll (`swipeUp; shot:`) show markup/syntax colours intact on newly
  revealed text. If they do not, keep it and say why in the commit.
- `EditorContainerViewController`: build the ⋯ menu with
  `UIDeferredMenuElement.uncached` reading `document` at open time, so a save
  never rebuilds the trailing controls; set `header.title` only when it
  changed. Keep `ellipsisMenuForTesting` returning the resolved children
  (tests read the export submenu by identifier).
- `WriterAppDelegate`: remove the dead `applicationDidEnterBackground`; keep
  `applicationWillTerminate`.
- `DocumentSession.unsavedChangesDidChange` → `protocol
  DocumentSessionObserving: AnyObject { func documentSessionUnsavedChangesDidChange(_:) }`
  with a `weak var observer`; `OpenSessionRegistry` adopts it.

### Verification (orchestrator)

Merge WP branches into `writer-polish`, resolve conflicts, then
`scripts/run_tests.sh --fresh`, a UI-driver run of the restore flow on the
simulator (open a sheet, type, background, relaunch, `shot:`), merge to
`main`, delete worktrees, build to the iPhone 16 Pro (iOS 27 → Xcode 27 beta
`DEVELOPER_DIR`).

## Addendum (same day): a minimal writing surface and Nodes-style live Markdown

Owner request: the document surface should be as minimal as possible to
leave room for the text. Hide the header and top controls while typing;
bring them back when the document is scrolled to its top or on a
double-tap on blank space (toggle). Always hide on keyboard focus, always
show when focus is lost. Mirror the Markdown editing behaviour of Nodes
(nodes-web.com), whose editor is open source as
[nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine)
(Apache 2.0, AppKit + TextKit 2). A clone is under the session scratchpad
for reading; port ideas and small routines with attribution, never the
package (it is AppKit-only).

What the Nodes engine does that Writer does not (read from its source):

- **Markers are hidden by size, not colour.** Every Markdown marker run
  (`#`, `*`, `_`, `` ` ``, `>`, list bullets, `[ ]`) is set to a 0.1 pt
  font plus a per-character negative kern that collapses the run to zero
  width (`MarkdownStyler.hiddenRunKern`). The source is untouched, so
  offsets map one to one. Writer today only greys markers (`MarkupLayer`).
- **The caret reveals.** Markers on the paragraph holding the caret (or
  touched by a selection) render at full size; leaving the paragraph
  collapses them again. The restyle is scoped to the old and new caret
  paragraphs (`NativeTextViewCoordinator+TextDelegate`).
- **Painted decorations** come from an `NSTextLayoutFragment` subclass
  (`MarkdownTextLayoutFragment`): a `•` over a hidden bullet marker, a
  vertical bar per blockquote level in the gutter, a full-width rule for a
  thematic break, a checkbox for a task item. Fonts and paragraph styles
  stay attributes.
- A collapsible scrolling header (`ScrollingHeaderController`).

### WP-C1 — Chrome that gets out of the way (Sonnet, after WP-A merges)

Organiser tier plus one seam. `EditorContainerViewController` owns the
`NavHeaderBar`; the editor reports the cues.

- `DocumentEditing` gains a chrome seam: `protocol EditorChromeObserving:
  AnyObject { func editorDidBeginEditing(_:); func editorDidEndEditing(_:);
  func editor(_:, didScrollToTop atTop: Bool); func editorDidRequestChromeToggle(_:) }`
  (names indicative), with `weak var chromeObserver`. `EditorViewController`
  drives it from `textViewDidBeginEditing` / `textViewDidEndEditing`,
  `scrollViewDidScroll` (at top ⇔ `contentOffset.y <= -adjustedContentInset.top + 1`),
  and a two-tap `UITapGestureRecognizer` on the text view that fires only
  when the tap point is not over a glyph (`closestPosition` lands at the
  document end or the tapped line fragment does not contain the point);
  the recogniser must not delay the single tap (`delaysTouchesEnded = false`,
  no `require(toFail:)` from the text view's own gestures).
- Container: `setChromeHidden(_:animated:)`. Hidden: the header slides up by
  its height and fades; the editor's top constraint switches from the
  header's bottom anchor to the view's top anchor (the text view has
  `contentInsetAdjustmentBehavior = .always`, so the safe area still
  clears the notch); the read-along chip re-anchors to the safe-area top.
  Shown: the reverse. 0.25 s, `.easeInOut`, alongside `UIView.animate`
  with `layoutIfNeeded`. State machine: keyboard focus → hidden; focus
  lost → shown; scrolled to top → shown; double-tap blank → toggle; a
  toggle while the keyboard is up shows the header until the next
  keyboard event.
- Tests: `EditorContainerViewControllerTests` drive the fake editor's
  chrome observer and assert the header's hidden state and the editor's
  top constraint; an `EditorViewController` test that a double tap on
  blank space calls the observer and a tap on text does not.

### WP-C2 — Nodes-style live Markdown (Opus, starts now)

Editor tier only (`LunaWriterEditor`, `LunaWriterText` if a token needs a
range it does not expose). Source stays plain Markdown; nothing about the
file format, anchors or export changes.

- `LayoutAttributeStyler` gains a `revealRange: NSRange?` input (the caret
  paragraph, or the selection's paragraphs). Markers OUTSIDE it get the
  hidden font (`UIFont` at 0.1 pt, same family) and a negative kern that
  collapses the run to zero width (port `hiddenRunKern`, computing the run
  width with Core Text / `NSAttributedString.size()`). Markers INSIDE it
  keep the block font. Inline markers (`**`, `*`, `~~`, `==`, `` ` ``,
  link brackets/destination) and block markers (`#…# `, `> `, list
  bullets with their trailing space, `- [ ] `) alike. Code fence
  delimiters and the fenced code lines' content stay visible (they are
  the code). Headings keep their size; body ink stays as today.
- `MarkdownTextStorage` gains `setRevealRange(_:)` which restyles the old
  and new reveal paragraphs only (through `styler.apply(model, to:, in:)`
  and `edited(.editedAttributes …)`), and `EditorViewController
  .textViewDidChangeSelection` calls it. `processEditing`'s rescan must
  apply the same reveal, so the styler must read the reveal range from
  the storage, not from a call argument (keep `LayoutAttributeStyler:
  Equatable` — the reveal range is storage state, not styler identity).
- `MarkupLayer` stops greying hidden markers (they are invisible) and
  greys only revealed ones; keep code tint and link colour.
- A `WriterTextLayoutFragment: NSTextLayoutFragment` installed through
  `NSTextLayoutManagerDelegate.textLayoutManager(_:textLayoutFragmentFor:in:)`
  on `WriterTextView`'s layout manager (the delegate is `EditorViewController`
  or a small `WriterLayoutFragmentProvider` object owned by the text view)
  paints: `•` at the hidden bullet marker's position (colour
  `EditorTheme.markup`), one `EditorTheme.quoteBar` bar per blockquote
  depth in the gutter (`metrics.quoteIndent` per level), a hairline rule
  across the column for a thematic break (the `---` collapses), and a
  checkbox glyph for a task item (`☐`/`☑` via SF Symbols `square` /
  `checkmark.square`, drawn as an image). Decorations are suppressed on
  the revealed paragraph so the raw syntax is what the writer edits. The
  fragment reads block kinds from the storage's `MarkdownDocumentModel`
  by character offset; keep it free of per-draw allocations beyond the
  path.
- Tapping a checkbox toggles the task (`MarkdownEditingCommands
  .toggleTask`) — the text view's `WriterTextView` intercepts a tap whose
  point lies within the hidden `[ ]` marker's line-fragment leading gutter.
- Caret geometry: the caret at a hidden run's boundary must not vanish.
  Verify on the simulator with the UI driver that typing `**bold**` then
  moving the caret off the line collapses the stars and moving back
  reveals them; that headings, lists, quotes, rules and tasks render;
  that undo, paste and Focus mode still work. Screenshots go in the
  report.
- Tests: `MarkdownTextStorageTests` — a marker outside the reveal range
  carries the hidden font and a kern whose sum cancels its width; a marker
  inside the reveal range carries the block font; moving the reveal range
  restyles exactly the two paragraphs (observer ranges). A layout-fragment
  test that a bullet line yields a `WriterTextLayoutFragment` and a
  paragraph line does not. Existing suites: `MarkdownTextStorageTests`,
  `RenderingAttributeComposerTests`, `FocusModeControllerTests`,
  `WriterEditingCommandsTests`, `WriterMarkdownScannerTests` stay green.
- Attribution: a `THIRD_PARTY_NOTICES.md` at the repo root naming
  swift-markdown-engine (Apache 2.0, copyright holder from its LICENSE) and
  a one-line header note in each file that ports a routine.
