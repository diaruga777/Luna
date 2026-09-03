# Luna Writer review — `LunaWriterReadAlong` + `LunaWriter/WriterReadAlongWiring.swift` (2026-09-03)

Reviewer: Opus subagent, read-only. Verified by reading the call paths end to end; unverified items say so. Severity: P0 crash/data loss, P1 wrong behaviour, P2 perf/leak, P3 simplification.

## `LunaWriter/WriterReadAlongWiring.swift`

### 1. Voice annotations are destroyed by the next autosave — P0 (data loss)
`WriterReadAlongWiring.swift:92-94` gives the coordinator `storage.library` as its `DocumentMarksStoring`, so `ReadAlongMarkStore.append` (`ReadAlongMarkStore.swift:31-35`) read-modify-writes the marks row directly. The open `DocumentSession` holds its own annotation set, loaded once at open (`DocumentSession.swift:78`), and `save()` replaces the whole row from that set (`DocumentSession.swift:187-188`). Speak "cut" → mark stored → type one character → autosave → the voice mark is gone; a comment's `WriterNote` is orphaned. `clearAnnotations()` loses the same race in reverse.
**Fix:** read-along must not write `marks`. Add `addAnnotation(_:)` / `removeAnnotation(_:)` to `ReadAlongTextHosting`, back them with `DocumentSession.add(_:)` / `.removeAnnotation(_:)` (`DocumentSession.swift:111,122`, currently test-only callers), delete `ReadAlongMarkStore`'s annotation half. Keep the note half.

### 2. Every opened sheet leaks its editor, its ARSession and its microphone — P0
`Session` holds `coordinator` strongly and `screen` weakly (`:71-78`); `prune()` (`:106-108`) drops a session only when `screen == nil`. `ReadAlongCoordinator.host` is a strong `let` (`ReadAlongCoordinator.swift:67`) to the same screen, so `screen` never becomes nil. `coordinator.stop()` is called from nowhere in production. Closing a sheet leaves the `CADisplayLink`, `ARSession`, `AVAudioEngine`, `DocumentSession` and text storage alive; one set per sheet ever opened.
**Fix:** make `host` weak (as `AnnotationPresenter.host` is), add a teardown method to `ReadAlongChromeProviding` (`LunaWriterLibraryUI/Environment.swift:30-32`) that `EditorContainerViewController` calls on close, which calls `coordinator.stop()` and drops the session.

### 3. The reading band never renders: both bridges claim `LayerID.reading` — P1
`ReadAlongLayerBridge.identifier` is hard-coded `.reading` (`:14`); `start()` installs two layers through it (`ReadAlongCoordinator.swift:180-181`). `RenderingAttributeComposer.addLayer` calls `removeLayer(layer.identifier)` first (`RenderingAttributeComposer.swift:39-43`), so the second install evicts the first. The editor already installs its own `.annotation` layer fed by the session (`EditorViewController.swift:81,156`).
**Fix:** pass the id into the bridge (`.reading` for the band). Delete `LunaWriterReadAlong.AnnotationLayer` and `ResolvedAnnotation`; let the editor's layer draw marks from the session (also fixes #1).

### 4. The HUD's constraints are unsatisfiable, and it is not where the design says — P1
`ReadAlongHUDView.swift:79-80` pins `width == 66, height == 34`; the container pins `leading` and `trailing` to the view (`EditorContainerViewController.swift:84-85`). Autolayout logs a break on every sheet open and the chip becomes a full-width 34 pt band that pushes the editor down; the design wants a top-trailing pill (`writer-app.md:628`).
**Fix:** constrain `trailing` to `layoutMarginsGuide.trailingAnchor` only; overlay the chrome rather than using it as the editor's top anchor.

### 5. Nothing restarts gaze after calibration, and two ARSessions collide — P1
`present(style:from:applyingTo:)` (`:126-132`) presents `GazeCalibrationViewController`, which builds its own `ARFaceGazeTracker` and starts it (`GazeCalibrationViewController.swift:70,238`) while the coordinator's tracker is running. On dismissal the coordinator's `isRunning` is still `true`, so its ARSession stays paused. Gaze is dead until the sheet is reopened.
**Fix:** suspend the coordinator before presenting; resume in all three delegate exits.

### 6. Calibrating from Settings never reaches a running session — P1
`presentCalibration(from:)` passes `applyingTo: nil` (`:122-124`); a live coordinator holds its fit from `init` (`ReadAlongCoordinator.swift:151`) and never re-reads the store.
**Fix:** broadcast the new calibration to live sessions, or re-read the store on resume.

### 7. A refused permission is silent — P2
`WriterReadAlongChrome` does not implement `readAlongCoordinator(_:didRefusePermissionFor:)` (default at `ReadAlongCoordinator.swift:38-39`). After denial `GazeTrackingPermission.request` returns `.denied` synchronously (`GazeTracker.swift:80-83`); the menu item does nothing forever.
**Fix:** implement it; alert with `openSettingsURLString`.

## `ReadAlongCoordinator.swift`

### 8. `refreshLayout()` runs before any layout pass and never runs again — P0 (feature inert)
`start()` calls `refreshLayout()` (`:183`) → `editor.sentenceGeometry.layout(for: 0..<textLength)` (`WriterReadAlongWiring.swift:38-40`). `start()` is reached from `EditorContainerViewController.viewDidLoad:80`, before the editor's constraints are activated (`:89-96`) and before any layout pass. Bounds and the text container are `.zero`; `layouts == []`. Nothing calls `refreshLayout()` again; the editor exposes no layout/scroll/re-wrap seam. `reading.setLayout([])` leaves the tracker unstarted; `currentAnchor()` returns nil at `:451`, so no voice annotation is ever stored in the shipped app. Tests pass because `FakeReadAlongHost.sentenceLayouts()` returns a precomputed array (`ReadAlongTestSupport.swift:116`). Confident about the zero bounds; not run end to end.
**Fix:** call `refreshLayout()` from the editor's first `viewDidLayoutSubviews` and on every text change / re-wrap / bounds change, through a seam on `DocumentEditing`.

### 9. With gaze off or paused, the sheet auto-scrolls itself and the user cannot stop it — P1
`readAlongDidTick` guards `updateBand` on `lastGateReason == .ok` but runs `assistScroll` unconditionally (`:377-378`). `ReadingTracker.lastGateReason` defaults to `.ok` (`ReadingTracker.swift:183`) and `ingest` is never reached when `state.isTracking` is false (`:326`), so a voice-only or paused session sweeps at 230 wpm from sentence 0 and `assistScroll` drags `contentOffset.y` up to 18 pt per frame (`:401-414`). `ScrollAssist` suppression is dead: `userDidScroll()` has no production caller.
**Fix:** guard the tick body on `state.isTracking && lastGateReason == .ok`; reset `lastGateReason` to `.away` when gaze goes off; wire `userDidScroll()` to `scrollViewWillBeginDragging` + `scrollViewDidScroll` (when tracking/decelerating).

### 10. Landscape and iPad are wrong three times over — P1
`interfaceOrientation` (`:105`) is never assigned, so `orientedScreenPoint` always takes the portrait branch (`:332-335`). `calibration` is loaded from the portrait slot only (`:151`) while the calibration VC saves under the current orientation. `gate` is built with the portrait screen size (`:149`), so in landscape x = 700 on an 852-wide screen is `.offScreen`.
**Fix:** observe the window scene's `interfaceOrientation` (as the calibration VC does at `:255-257`); on change re-set orientation, reload calibration, reset the gate's size.

### 11. `viewportOrigin` is a window point compared against a screen point — P1 on iPad
`ingest` subtracts `viewportOrigin = host.scrollView.convert(.zero, to: nil)` (`:368-370`), the window's space. In Split View / Slide Over / Stage Manager the window origin on the display is non-zero.
**Fix:** convert to `scrollView.window?.screen.coordinateSpace`, falling back to the current behaviour for headless tests.

### 12. Double-tapping a permission toggle ends with the feature off — P2
`setGazeEnabled(true)` guards at `:207` but flips state inside the async callback (`:221`); `applyGazeToggle` toggles rather than sets (`ReadAlongState.swift:97-102`). Same shape in `setVoiceEnabled` (`:229-248`). Hold an `isRequestingPermission` flag; set the requested value.

### 13. `stop()` leaves session state that the next `start()` inherits — P2
`:190-200` does not clear `pendingAnchor`, `lastGateReason`, `lastGazePoint`, `lastFixation`, `layouts`, the trace; removes one overlay layer for two installed; never removes the diagnostics view (`:534-537`). Reset all and hide diagnostics.

### 14. No app-lifecycle handling — P2
Nothing observes `willResignActive`/`didEnterBackground`; `ARFaceGazeTracker` has no `sessionInterruptionEnded`. Stop both halves on background; re-run `applyGazeRunState()` / `applyVoiceRunState()` on foreground.

### 15. `UIScreen.main` / `UIDevice.current.userInterfaceIdiom` in the initializer — P3 (P1 for Mac)
`:130-131` (and `GazeCalibrationViewController.swift:66-67`). Take size and idiom from the presenting window scene.

### 16. `onMain` is redundant — P3
Both transcribers already hop to main before the delegate call (`SFSpeechTranscriber.swift:118-130`, `SpeechAnalyzerTranscriber.swift:103-110`); `onMain` (`:564-570`) never takes its async branch, and if it did it would defeat the onset-snapshot contract. Delete it; state the main-thread requirement on `SpeechTranscribingDelegate`.

## `ReadingLayer.swift`

### 17. A stationary band invalidates the editor's rendering pass 60 times a second — P2
`update(sentence:readUpToWord:)` (`:58-72`) invalidates unconditionally; `refreshColours()` is called per frame from `layoutMirror` (`:127`). Early-return when `bandRange`, `trailRange`, `bandSentence` are unchanged; cache mirror colours, refresh on `LunaSkyTrait` change (`:45`).

### 18. The mirror is not moved when the page scrolls without a gaze frame — P2
`layoutMirror` is reached only through `updateBand`, gated on `lastGateReason == .ok` (`ReadAlongCoordinator.swift:377`). Call `layoutMirror` with the last sentence every tick; gate only the model update.

## `GazeCalibrationViewController.swift`

### 19. `.offScreen` frames are fitted as if the user were looking at (0, 0) — P1
`gazeTracker(_:didProduce:)` leaves `raw = .zero`, `faceTracked = true` for `.offScreen` (`:280-283`); `CalibrationSampleCollector.ingest` rejects only on `!isFaceTracked` or blink (`CalibrationSampleCollector.swift:93`), blink always 0 (`:294`). Every off-screen frame becomes `(raw: (0,0), target: dot)`. Treat `.offScreen` as unusable.

### 20. Rotation mid-calibration invalidates the run silently — P1 on iPad
`begin()` captures `bounds` once (`:229`); `currentOrientation` is re-read per sample (`:279`). Lock `supportedInterfaceOrientations` for the run, or cancel and restart on `viewWillTransition`.

### 21. A failed run leaves the camera on — P2
`render(stage: .failed)` (`:320-322, 351-358`) neither stops the tracker nor the ticker; only `cancel()`/`finish()` do (`:220-225, 244-246`).

### 22. The fit is made in view coordinates and consumed as screen coordinates — P2, unverified
`begin()` fits against targets in view space (`:229-231`) while raw inputs are display points (`:276-279`). In a non-full-screen window the window origin is folded into the bias. Fit in display coordinates; record the window frame.

## `GazeCalibrationFlow.swift`

### 23. `estimatedDuration` (`:220-223`) is dead — P3. The HUD hard-codes "(25s)"/"(8s)" (`Localizable.strings:1433,1438`). Use it or delete it.

## `ReadAlongState.swift` / `ReadAlongAvailability.swift`

### 24. `needsCalibration` (`ReadAlongState.swift:91-93`) and `voiceReason` (`ReadAlongAvailability.swift:21`) are test-only — P3. Use them (HUD first-run offer; Settings reason) or delete them plus their tests.

## `AnnotationPresenter.swift` / `AnnotationPopoverViewController.swift`

### 25. The entire manual-annotation half is unreachable — P1 (feature missing) / P3 (dead code)
`AnnotationPresenter` is never constructed. Tapping a mark opens nothing; `readAlongMenuElements(for:)` is never asked; no `.manual` annotation can be made.
**Fix:** wire it (one per session in `WriterReadAlongChrome`, hand `readAlongMenu(for:)` to the editor's edit menu, route the text view's tap through `presentPopover(forContainerPoint:from:in:)`), or delete both files and the protocol.

### 26. The popover names no delegate — P2 on iPad/iPhone
`present(_:from:in:)` (`AnnotationPresenter.swift:71-73`) sets `sourceView`/`sourceRect` but no `popoverPresentationController?.delegate`, so on compact width it becomes a full-screen modal with no dismissal. Return `.none` from `adaptivePresentationStyle`, or wrap in a form sheet with Done on compact.

### 27. `annotation(atContainerPoint:)` (`:45-50`) re-lays the whole document per tap — P2. Use the coordinator's cached `layouts` or `sentenceGeometry.visibleSentences()` (`SentenceGeometryProvider.swift:54`, currently uncalled).

## `ReadAlongTheme.swift`

### 28. A second annotation colour table that disagrees with the editor's — P2
`ReadAlongTheme` raw hexes (`:18-22`) vs `EditorTheme`'s `lifted(...)` (`EditorTheme.swift:102-106,125`); a third band colour in `EditorTheme.readingBand` (`:118-121`) is ignored for `GlassStyle.readingAccent`. One table, in `EditorTheme`.

## `SessionTrace.swift`

### 29. A 6 000-frame ring buffer nothing can export — P2
`trace.record` runs every tick (`ReadAlongCoordinator.swift:380`); `exportTrace(from:)` (`:559-562`) has no caller. Add the menu item behind diagnostics, or trace only when diagnostics is on.

## `ReadAlongDiagnosticsView.swift`

### 30. Full-document redraw every frame while visible — P2 (`:89`, `:117-130`, `:88`). Cull by index range; throttle text to ~4 Hz; redraw only on change.

## `ReadAlongTicker.swift`

### 31. `DisplayLinkTicker` cannot deinit itself — P2
`CADisplayLink(target: self, …)` retains the ticker (`:52-55`); `deinit` (`:46-48`) is unreachable unless `stop()` runs, which #2 prevents. Use a weak proxy target.

## Threading
Nothing wrong, nothing stated. Gaze samples arrive on main (`GazeTracker.swift:183-193`), the display link fires on main, both transcribers hop to main, both permission completions land on main. `ReadAlongCoordinator` is not `@MainActor` while its only owner `WriterReadAlongChrome` is (`:64`). Mark the coordinator `@MainActor`; state the main-thread contract on `GazeTrackingDelegate` and `SpeechTranscribingDelegate`.

## Mac portability
`ReadAlongCoordinator.swift:137` and `GazeCalibrationViewController.swift:70` default to `ARFaceGazeTracker()`; `UIScreen.main` (`:130`, calibration VC `:66`), `UIDevice.current.userInterfaceIdiom` (`:131`), `UIInterfaceOrientation` (`:105`), per-orientation store slots, `prefersStatusBarHidden` are iOS-shaped. The two halves are already independent in `ReadAlongAvailability` and `ReadAlongState`.
**Fix:** a `GazeTrackerMaking` witness installed by the composition root (nil on Mac → gaze half hidden → `currentAnchor()` takes its fallback, `:461-469`, ideally a caret/selection case on Mac). Then `LunaGaze`'s ARKit file sits behind `#if canImport(ARKit)` inside the module (platform gating, not target gating).

## What is solid
The onset-snapshot design and its test (`ReadAlongCoordinatorTests.swift:18-48`); `ReadAlongGeometry` as pure arithmetic over named spaces; `ScrollAssist` as a pure tested value type; `ReadAlongState`'s two-durable-inputs discipline; clock-free `GazeCalibrationFlow`; `SessionTrace` as a bounded ring buffer; `ReadAlongMarkStore`'s centralised read-modify-write (right idea, wrong store).

## Test gaps
1. No test drives `WriterReadAlongChrome` (would catch #2, #3). 2. No test asserts a voice annotation survives `DocumentSession.save()` (#1). 3. No voice-only tick test (#9). 4. No pause-while-ticking test. 5. No orientation test (#10). 6. No non-zero `viewportOrigin` test (#11). 7. No `.offScreen` calibration frame test (#19). 8. No `stop()`/`start()` cycle test (#13). 9. No invalidation-count test on a stationary band (#17; `RenderingInvalidationSpy` exists at `ReadAlongTestSupport.swift:232`).
