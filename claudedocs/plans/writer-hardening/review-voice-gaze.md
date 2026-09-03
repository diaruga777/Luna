# Luna Writer review — `LunaWriterVoice` and `LunaGaze` (2026-09-03)

Scope: every file in both modules, the consuming coordinators in `LunaReaderUI` and `LunaWriterReadAlong`, the test suites. Reviewer: Opus subagent, read-only. Findings verified against code paths unless marked otherwise. Severity: P0 crash/data loss, P1 wrong behaviour, P2 perf/leak, P3 simplification.

## LunaWriterVoice/SFSpeechTranscriber.swift

**1. The recognition task stops the transcriber for good on the first final result — P1**
`SFSpeechTranscriber.swift:79-87`, `:90-100`. `SFSpeechRecognitionTask` with `shouldReportPartialResults = true` delivers `isFinal` once — at `endAudio`, at an error, or at the recognizer's duration limit. The callback then calls `self.stop()`, which removes the tap, stops the engine, deactivates the audio session and nils the task. Nothing restarts it. The iOS 18 path yields at most one utterance per session; after the limit the mic is dead while `ReadAlongState.isListening` still reads true. Fix: on a final result or an error, tear down only the request/task and open a new `SFSpeechAudioBufferRecognitionRequest` + task against the still-running engine; keep `stop()` for the caller's teardown.

**2. Nothing closes an utterance between finals — `UtteranceSegmenter.tick()` is production-dead — P1**
`UtteranceSegmenter.swift:67-73`; `SFSpeechTranscriber.swift:111-115`; `SpeechAnalyzerTranscriber.swift:71-84`. `tick()` is called only from tests. The 400 ms silence boundary and the 20 s cap never fire in production. Fix: drive `tick()` from the tap callback (~20×/s) or from the read-along display link, and hop the returned utterance to main.

**3. `VoiceActivityEvent.end` is computed and discarded — P2**
`EnergyVAD.swift:82-91`; `SFSpeechTranscriber.swift:105`; `SpeechAnalyzerTranscriber.swift:102`. Both transcribers filter `where event == .onset`. Forward `.end` (it is the natural signal for #2 and #33), or delete the state.

**4. `.duckOthers` is not a legal option for the `.record` category — P1 (verify on device)**
`SFSpeechTranscriber.swift:57`; `SpeechAnalyzerTranscriber.swift:50`. `.duckOthers` is documented only for `playAndRecord`, `playback`, `multiRoute`. `setCategory(.record, mode: .measurement, options: [.duckOthers])` is expected to throw -50, which `ReadAlongCoordinator.applyVoiceRunState` swallows by setting `voiceAvailable = false`. Fix: drop the option or use `.playAndRecord`.

**5. No route-change, configuration-change or interruption handling — P1**
`SFSpeechTranscriber.swift:68-77`; `SpeechAnalyzerTranscriber.swift:61-69`. Neither observes `AVAudioSession.interruptionNotification`, `routeChangeNotification` or `.AVAudioEngineConfigurationChange`. Fix: observe all three; on resume re-install the tap with the node's current format and restart the engine.

**6. `stop()` can run concurrently from two threads — P2**
`SFSpeechTranscriber.swift:84-86` (recognition queue) and `applyVoiceRunState` (main). Confine the class to `@MainActor` or serialise on a private queue.

**7. Per-frame array and `Date` allocation on the audio render thread — P2**
`EnergyVAD.swift:105-129` (`:123` `Array(UnsafeBufferPointer(...))`, `:110`/`SFSpeechTranscriber.swift:103` `Date()`). Compute RMS in place (`vDSP_rmsqv`) and stamp frames from the tap's `AVAudioTime`.

## LunaWriterVoice/SpeechAnalyzerTranscriber.swift

**8. The results loop is attached after `analyzer.start` — P1 (moderate confidence)**
`SpeechAnalyzerTranscriber.swift:71-79`. Apple's sample starts `for try await result in transcriber.results` before `analyzer.start(inputSequence:)`. Reverse the order; surface the caught error at `:80-83`.

**9. No per-locale model check and no installation request — P1**
`:32-38`, `:42-44`, `:56`. `SpeechTranscriber.isAvailable` does not say the asset for `locale` is installed; no `AssetInventory` path. Report `.noOnDeviceModel` or request installation.

**10. `stop()` never finalises the analyzer — P2** (`:87-97`). Call `finalizeAndFinishThroughEndOfInput()` before cancelling.

**11. The two transcribers disagree about which permissions they need — P3**
`SFSpeechTranscriber.swift:49-54` checks speech + mic; `SpeechAnalyzerTranscriber.swift:45-47` mic only; `VoicePermissions.swift:32-38` asks for both. Make them match.

## Availability

**12. Voice availability is latched before the permission is ever asked, and cannot recover — P1**
`ReadAlongAvailability.swift:30-36`; `SFSpeechTranscriber.swift:32-35`; `WriterReadAlongWiring.swift:81-85`; `ReadAlongCoordinator.swift:154-161`, `:237`. `SFSpeechRecognizer.isAvailable` is false while unauthorized; availability is resolved once at wiring time. First launch yields `voice = false` and the user can never turn voice on; if gaze is also unavailable the chrome `init?` returns nil for the process lifetime. Fix: treat "unasked" as distinct; ask, then re-resolve; re-resolve on `didBecomeActive`.

## LunaWriterVoice/VoiceCommandClassifier.swift

**13. The lexicon is rebuilt on every classification — P3** (`:15-30`). Hoist to `static let`.

## LunaGaze/GazeTracker.swift

**14. `UIScreen.main` read from an ARKit delegate callback, once per frame — P2**
`GazeTracker.swift:104-106` from `:161-181`. Main-safe only because `delegateQueue` is nil; deprecated in iOS 26; wrong under Stage Manager. Capture the size once at `start()` from the window scene and refresh on geometry change.

**15. `isRunning` written from two threads — P2** (`:95`, `:124`, `:130`, `:136`, `:148`). Mark the class `@MainActor`.

**16. No `sessionInterruptionEnded`; a failed session is never paused — P2** (`:146-153`). Implement `sessionInterruptionEnded` with `run(configuration, options: [.resetTracking, .removeExistingAnchors])`; pause on failure.

**17. Blink is dropped at the tracker boundary, so the gate's blink leg is dead in the Writer — P1**
`GazeTracker.swift:161-181`; `GazeGate+ARKit.swift:15-22`; `ReadAlongCoordinator.swift:343-348` (`blinkLeft: 0, blinkRight: 0`); `GazeCalibrationViewController.swift:285-294` (`blink: 0`). Blink garbage flows into the filter and the reading model. Fix: add a parallel `GazeFrame` (point, blink pair, face-tracked flag) via a second optional delegate method; leave `GazeSample` as the Reader sees it.

## LunaGaze/GazeScreenProjection.swift

**18. Points-per-inch by idiom is wrong for several devices — P2** (`:30-33`). 3× iPhones ~153 pt/in (6 % off); iPad mini 163 pt/in (23 % off), propagating into every `VisualAngle` threshold (`VisualAngle.swift:23-27`). Derive from `nativeScale`/native bounds or a per-machine table.

**19. The projection assumes the camera sits at the top centre of the portrait display — P1 for iPad**
`:39`, `:64-66`. iPads with the camera on the long edge are off by half a screen before calibration. Make the camera position an explicit per-device parameter.

**20. `orientedScreenPoint` is correct, but its consumers pass the wrong companion size — P1**
`GazeScreenProjection.swift:79-96`; `GazeGate.swift:108-111`; `ReadAlongCoordinator.swift:149`, `:299-303`. The gate is built with the portrait size (`:149`) and fed the oriented point (`:346-348`); in landscape every sample is `.offScreen`. `viewDidResize(to:)` sets `gate.screenSize` to the sheet view size, a third space. Fix: give the gate the oriented screen size and update it on rotation.

## LunaGaze/OneEuroFilter.swift

**21. One non-finite sample wedges the filter for the rest of the session — P1** (`:67-99`). Add `guard point.x.isFinite, point.y.isFinite else { reset(); return currentValue ?? point }`; same guard in `GazeAffineCalibration.point(from:)`.

**22. The ray-plane guard admits near-parallel rays — P3** (`GazeScreenProjection.swift:55-62`). Reject hits beyond ~2 m of travel.

## LunaGaze/ReadingTracker.swift

**23. Every sentence in the document is scored with two `exp` calls every frame, on main — P2**
`ReadingTracker.swift:345-359`; `GazeTextGeometry.swift:61-83`; `WriterReadAlongWiring.swift:38-40` passes the whole sheet. Cache `bounds` in `SentenceLayout`; restrict scoring to a ±6 window plus a vertical band pre-filter (behaviour-preserving within epsilon); assert in a test.

**24. `setLayout` keeps `progress` although its comment says it does not — P2** (`:211-219`). Reset `progress`, `doneAt`, `snapCandidate`, or fix the comment.

**25. The residual freezes while gaze is lost and can still trigger the recalibration nag — P3** (`:371`; `GazeDriftCorrector.swift:164-174`). Decay or gate on `hasGaze`.

## LunaGaze/CalibrationSampleCollector.swift + GazeCalibrationFlow

**26. The collector's `startTime` is fixed at construction, so the production sweep pairs nothing — P1, feature-dead**
`CalibrationSampleCollector.swift:54` (`private let startTime`), `:117`; `GazeCalibrationFlow.swift:95-99`, `:111-116`; `GazeCalibrationViewController.swift:230-240`. The VC builds the flow with `startTime: 0`; `flow.begin(at: clock.now)` updates the flow's start but not the collector's. Frame times are `CACurrentMediaTime()` (uptime), so `path.sample(at: frame.time - 0 - lag)` always lands past `duration` and every buffer stays empty. `.quick`/`.region` fail the 40-sample minimum; `.full` fits only head-turn samples at one point. Tests hide it because every clock starts at 0. Fix: make `startTime` a `var` the flow sets in `begin`; add a flow test with a large clock offset.

## LunaGaze/GazeAffineCalibration.swift

**28. A single non-finite sample kills the whole fit — P2** (`:436-452`, `:470-491`). Filter non-finite samples before building the design. (Degenerate identical-point case verified non-singular thanks to the ridge term.)

**29. `validate` classifies quadrants against a size while its targets carry an origin — P3** (`:355-360`; `GazeCalibrationFlow.swift:93`, `:196`). `viewSizeDrift` (`:393-397`) compared against an editor column would nag falsely once `viewDidResize` is wired. Store the reference rect.

## LunaGaze/GazeCalibrationStore.swift

**30. The per-orientation store is written per orientation and read as portrait only — P1**
`GazeCalibrationStore.swift:26-31`; `GazeCalibrationViewController.swift:251`, `:255-257`; `ReadAlongCoordinator.swift:151` loads `.portrait`, hard-coded, once. Load for the current orientation and re-load on rotation.

## Integration (LunaWriterReadAlong)

**31. A read-along session is never released, so the camera, the microphone and a display link run forever — P0**
`LunaWriter/WriterReadAlongWiring.swift:99`, `:106-108`; `ReadAlongCoordinator.swift:67` (`private let host: ReadAlongTextHosting`). `sessions` holds each `Session` strongly; `Session.screen` is weak, but the coordinator holds the same screen strongly through `host`, so `prune()` never removes anything. `ReadAlongCoordinator.stop()` is called nowhere in the app. Closing a sheet leaves the `ARSession`, the `AVAudioEngine`, the `CADisplayLink`, and the whole `WriterEditorScreen` + `DocumentSession` + TextKit stack alive — one set per sheet ever opened. Fix: hold the coordinator from the editor screen's lifetime and call `stop()` in `viewDidDisappear`/on close; key `sessions` weakly.

**32. Four of the coordinator's inputs are never fed — P1**
`ReadAlongCoordinator.swift:105` (`interfaceOrientation`), `:286-289` (`refreshLayout`), `:292-296` (`userDidScroll`), `:299-303` (`viewDidResize`). No caller outside tests. Gaze is never rotated; sentence geometry goes stale on the first keystroke; scroll assist fights the user. Fix: editor calls `refreshLayout` on layout invalidation, `userDidScroll` from `scrollViewWillBeginDragging`, orientation/size from `viewWillTransition(to:with:)`.

**33. The spoken anchor never expires — P1** (`ReadAlongCoordinator.swift:431-442`; `EnergyVAD.swift:43-49`). A cough sets `pendingAnchor`; the next real remark minutes later is filed on that line. Stamp and expire after ~2 s, or clear on VAD `.end`.

**34. No app-lifecycle handling anywhere in read-along — P2**. Stop both halves on background, restart on foreground, mirroring `RSVPGazeCoordinator.syncTracker`.

## Mac portability

Portable already (Foundation/CoreGraphics/simd only): `ReadingTracker`, `GazeGate`, `OneEuroFilter`, `FixationDetector`, `GazeTextGeometry`, `GazeAffineCalibration`, `PursuitCalibrationPath`, `GazeDriftCorrector`, `CalibrationSampleCollector`, `GazeSample`. Blockers: `GazeTracker.swift:6,10` (ARKit, UIKit), `GazeGate+ARKit.swift:6`, `GazeScreenProjection.swift:8` / `VisualAngle.swift:8` / `GazeCalibrationStore.swift:8` (UIKit only for `UIUserInterfaceIdiom`/`UIInterfaceOrientation`). Recommendation: split `LunaGazeCore` (pure, with a plain `GazeOrientation` enum) from a thin `LunaGaze` adding the ARKit tracker, `#if canImport(ARKit)`-gated for platform. Remove the two couplings in `ReadAlongCoordinator`: `gazeTracker ?? ARFaceGazeTracker()` at `:137` and `screenSize: CGSize = UIScreen.main…` at `:130`.

## What is solid

`orientedScreenPoint` (all four cases re-derived), the ridge-toward-identity fit and MAD outlier pass, `ReadingTracker`'s clock-free design, `GazeGate`'s dropped-frame rule and freeze-not-guess, `FixationDetector`'s guard, `PursuitCalibrationPath` easing, `EnergyVAD`/`UtteranceSegmenter` as pure clocked objects.

## Test gaps

No test starts a clock anywhere but zero (hides #26). No landscape or iPad fixture (hides #18, #19, #20, #30, #32). No calibration-store round trip through the coordinator. No non-finite input test on `OneEuroFilter` or `fit`. No transcriber lifecycle test (no `AVAudioEngine` seam). `UtteranceSegmenter.tick()` tested but never called. No test asserts the session is torn down on sheet close (#31).
