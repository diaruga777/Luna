//
//  ReadAlongCoordinator.swift
//  LunaWriterReadAlong
//

import CoreGraphics
import Foundation
import LunaDesignSystem
import LunaGaze
import LunaModels
import LunaWriterModels
import LunaWriterStorage
import LunaWriterVoice
import UIKit

/// The reader of a read-along session's outcomes.
public protocol ReadAlongCoordinatorDelegate: AnyObject {
    func readAlongCoordinator(_ coordinator: ReadAlongCoordinator, didChange state: ReadAlongState)
    func readAlongCoordinator(_ coordinator: ReadAlongCoordinator, didAdd annotation: Annotation)
    func readAlongCoordinator(_ coordinator: ReadAlongCoordinator, didHear text: String)
    /// The gaze estimate has drifted, or the view changed shape enough to
    /// invalidate the fit. Offer a touch-up.
    func readAlongCoordinatorNeedsRecalibration(_ coordinator: ReadAlongCoordinator)
    /// A permission the user just opted into was refused.
    func readAlongCoordinator(
        _ coordinator: ReadAlongCoordinator, didRefusePermissionFor half: ReadAlongHalf)
}

/// Which half of read-along a message is about.
public enum ReadAlongHalf: Equatable { case gaze, voice }

extension ReadAlongCoordinatorDelegate {
    public func readAlongCoordinator(
        _ coordinator: ReadAlongCoordinator, didAdd annotation: Annotation) {}
    public func readAlongCoordinator(
        _ coordinator: ReadAlongCoordinator, didHear text: String) {}
    public func readAlongCoordinatorNeedsRecalibration(_ coordinator: ReadAlongCoordinator) {}
    public func readAlongCoordinator(
        _ coordinator: ReadAlongCoordinator, didRefusePermissionFor half: ReadAlongHalf) {}
}

/// Drives one sheet's read-along session: gaze in, band and annotations out.
///
/// Every stage between the camera and the reading model is a separate object
/// from `LunaGaze`, and this owns the order they run in: ARKit sample →
/// oriented screen point → affine calibration → One-Euro filter →
/// text-container coordinates → `ReadingTracker`. On each frame the reading
/// state moves the band, assists the scroll, and feeds the drift corrector.
///
/// Speech runs beside that, not through it. The anchor for an utterance is
/// snapshotted at ONSET — the line the reader was on when they started
/// talking — because by the time the transcript arrives the eyes have moved
/// on, usually to the words being discussed.
///
/// Every method runs on the main thread. `GazeTrackingDelegate` and
/// `SpeechTranscribingDelegate` both deliver there; so does the display link.
public final class ReadAlongCoordinator: NSObject, GazeTrackingDelegate,
                                         SpeechTranscribingDelegate, ReadAlongTickReceiving {

    // MARK: - Collaborators

    public weak var delegate: ReadAlongCoordinatorDelegate?

    public let documentID: DocumentID
    public let readingLayer = ReadingLayer()
    public let trace = SessionTrace()
    public let markStore: ReadAlongMarkStore

    /// The editor screen. Weak: the screen owns the editor and the session
    /// this reads through, and it must be able to go away with the sheet.
    public private(set) weak var host: ReadAlongTextHosting?
    private let settings: WriterSettings
    private let gazeTracker: GazeTracking?
    private let transcriber: SpeechTranscribing?
    private let calibrationStore: GazeCalibrationStore
    private let ticker: ReadAlongTicking
    private let clock: ReadAlongClock

    private let reading: ReadingTracker
    private var filter: OneEuroFilter
    private let fixationDetector: FixationDetector
    private var gate: GazeGate
    private var driftCorrector: GazeDriftCorrector
    private var scrollAssist = ScrollAssist()

    // MARK: - Session state

    public private(set) var state: ReadAlongState {
        didSet {
            guard state != oldValue else { return }
            delegate?.readAlongCoordinator(self, didChange: state)
        }
    }

    /// The affine fit in force. The drift corrector nudges its bias.
    public private(set) var calibration: GazeAffineCalibration
    public private(set) var isRunning = false
    /// Held for a calibration screen or the app being in the background:
    /// nothing captures, but `isRunning` and the user's settings stay.
    public private(set) var isSuspended = false
    /// The reading model's own view of the sheet.
    public var readingState: ReadingState { reading.state }
    public private(set) var lastGateReason: GateReason = .away
    /// The last calibrated gaze, in text-container coordinates.
    public private(set) var lastGazePoint: CGPoint?
    public private(set) var lastFixation: Fixation?
    public private(set) var layouts: [SentenceLayout] = []

    /// The display's size held upright, for rotating a portrait-origin sample.
    public var portraitScreenSize: CGSize {
        didSet { refreshOrientedGeometry() }
    }
    /// The orientation the sheet is presented in. Setting it reloads the fit
    /// made for that orientation and resizes the gate to the oriented screen.
    public var interfaceOrientation: UIInterfaceOrientation = .portrait {
        didSet {
            guard interfaceOrientation != oldValue else { return }
            refreshOrientedGeometry()
        }
    }
    public let pointsPerDegree: CGFloat

    private var pendingAnchor: SpokenAnchor?
    private var hasNagged = false
    private var diagnostics: ReadAlongDiagnosticsView?
    private var isRequestingGazePermission = false
    private var isRequestingVoicePermission = false

    /// How long an onset with no utterance behind it stays valid. A cough or
    /// a closing door trips onset; the remark that follows minutes later
    /// belongs to where the reader is then, not where the noise was.
    public static let anchorLifetime: TimeInterval = 8

    private struct SpokenAnchor {
        let range: NSRange
        let anchor: TextAnchor
        let time: TimeInterval
    }

    // MARK: - Life cycle

    /// - Parameters:
    ///   - gazeTracker: `nil` when this platform has no camera tracker; the
    ///     gaze half is then reported unavailable and voice runs alone.
    ///   - screenSize: the display's portrait size, from the window scene.
    ///   - idiom: decides the visual-angle scale.
    public init(
        documentID: DocumentID,
        host: ReadAlongTextHosting,
        notes: NoteStoring,
        settings: WriterSettings = WriterSettings(),
        gazeTracker: GazeTracking?,
        transcriber: SpeechTranscribing?,
        calibrationStore: GazeCalibrationStore = GazeCalibrationStore(),
        ticker: ReadAlongTicking = DisplayLinkTicker(),
        clock: ReadAlongClock = SystemReadAlongClock(),
        screenSize: CGSize,
        idiom: UIUserInterfaceIdiom
    ) {
        self.documentID = documentID
        self.host = host
        self.settings = settings
        self.markStore = ReadAlongMarkStore(documentID: documentID, notes: notes)
        self.gazeTracker = gazeTracker
        self.transcriber = transcriber
        self.calibrationStore = calibrationStore
        self.ticker = ticker
        self.clock = clock
        self.portraitScreenSize = screenSize

        let perDegree = VisualAngle.pointsPerDegree(idiom: idiom)
        self.pointsPerDegree = perDegree
        self.reading = ReadingTracker(pointsPerDegree: perDegree)
        self.filter = OneEuroFilter()
        self.fixationDetector = FixationDetector(pointsPerDegree: perDegree)
        self.gate = GazeGate(screenSize: screenSize, pointsPerDegree: perDegree)
        self.driftCorrector = GazeDriftCorrector(pointsPerDegree: perDegree)
        self.calibration = calibrationStore.calibration(for: UIInterfaceOrientation.portrait)
            ?? GazeAffineCalibration.identity(viewSize: screenSize, pointsPerDegree: perDegree)

        let availability = ReadAlongAvailability.resolve(transcriber: transcriber)
        self.state = ReadAlongState(
            gazeEnabled: settings.gazeEnabled,
            voiceEnabled: settings.voiceEnabled,
            gazeAvailable: gazeTracker != nil && availability.gaze,
            voiceAvailable: availability.voice || availability.voiceIsUnasked,
            calibrationGrade: settings.lastCalibrationGrade
                .flatMap(CalibrationVerdict.Grade.init(rawValue:)))
        super.init()

        self.gazeTracker?.delegate = self
        self.transcriber?.delegate = self
        self.ticker.target = self
    }

    deinit {
        gazeTracker?.stop()
        transcriber?.stop()
        ticker.stop()
    }

    /// Installs the band layer and starts whichever halves the user has
    /// already turned on. Geometry arrives through `refreshLayout()` once the
    /// editor has laid out; nothing here assumes it exists yet.
    public func start() {
        guard !isRunning, let host else { return }
        isRunning = true
        host.installOverlayLayer(readingLayer)
        readingLayer.attach(to: host.hostView)
        refreshLayout()
        ticker.start()
        applyGazeRunState()
        applyVoiceRunState()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        ticker.stop()
        gazeTracker?.stop()
        transcriber?.stop()
        state.isListening = false
        state.trackingLost = false
        readingLayer.detach()
        readingLayer.clear()
        host?.removeOverlayLayer()
        setDiagnosticsVisible(false)
        pendingAnchor = nil
        lastGateReason = .away
        lastGazePoint = nil
        lastFixation = nil
        hasNagged = false
        filter.reset()
        fixationDetector.reset()
        gate.reset()
        trace.reset()
    }

    /// Holds both halves without changing what the user chose — for a
    /// calibration screen that needs the camera, or the app leaving the
    /// foreground. `resume()` picks up where the settings say.
    public func suspend() {
        guard isRunning, !isSuspended else { return }
        isSuspended = true
        gazeTracker?.stop()
        transcriber?.stop()
        state.isListening = false
        state.trackingLost = false
        lastGateReason = .away
        readingLayer.clear()
    }

    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        reloadCalibration()
        applyGazeRunState()
        applyVoiceRunState()
    }

    // MARK: - Toggles

    /// Turns gaze on or off. Camera authorization is asked HERE — at the
    /// moment the user opts in — and nowhere else.
    public func setGazeEnabled(_ enabled: Bool) {
        guard enabled != state.gazeEnabled, !isRequestingGazePermission else { return }
        guard enabled else {
            state.gazeEnabled = false
            state.isPaused = false
            state.trackingLost = false
            settings.gazeEnabled = false
            applyGazeRunState()
            return
        }
        guard state.gazeAvailable else { return }
        isRequestingGazePermission = true
        GazeTrackingPermission.request { [weak self] status in
            guard let self else { return }
            self.isRequestingGazePermission = false
            guard status == .granted else {
                self.delegate?.readAlongCoordinator(self, didRefusePermissionFor: .gaze)
                return
            }
            self.state.gazeEnabled = true
            self.state.isPaused = false
            self.state.trackingLost = false
            self.settings.gazeEnabled = true
            self.applyGazeRunState()
        }
    }

    /// Turns spoken comments on or off, asking for the microphone and speech
    /// recognition at the moment of opt-in.
    public func setVoiceEnabled(_ enabled: Bool) {
        guard enabled != state.voiceEnabled, !isRequestingVoicePermission else { return }
        guard enabled else {
            state.voiceEnabled = false
            state.isListening = false
            settings.voiceEnabled = false
            applyVoiceRunState()
            return
        }
        guard state.voiceAvailable else { return }
        isRequestingVoicePermission = true
        VoicePermissions.request { [weak self] status in
            guard let self else { return }
            self.isRequestingVoicePermission = false
            guard status.isGranted else {
                self.delegate?.readAlongCoordinator(self, didRefusePermissionFor: .voice)
                return
            }
            self.refreshVoiceAvailability()
            self.state.voiceEnabled = true
            self.settings.voiceEnabled = true
            self.applyVoiceRunState()
        }
    }

    /// Holds tracking without forgetting that the user wants it.
    public func togglePause() {
        state.applyPauseToggle()
        applyGazeRunState()
    }

    private func applyGazeRunState() {
        guard isRunning, !isSuspended, state.isTracking, let gazeTracker else {
            gazeTracker?.stop()
            readingLayer.clear()
            lastGateReason = .away
            lastGazePoint = nil
            return
        }
        filter.reset()
        fixationDetector.reset()
        gate.reset()
        gazeTracker.start()
    }

    private func applyVoiceRunState() {
        guard isRunning, !isSuspended, state.isVoiceActive, let transcriber else {
            transcriber?.stop()
            state.isListening = false
            return
        }
        do {
            try transcriber.start()
            state.isListening = true
        } catch {
            state.isListening = false
            refreshVoiceAvailability()
        }
    }

    /// Re-asks the transcriber. An unasked permission keeps the toggle
    /// offered; only a hard no (denied, unsupported, no model) hides it.
    private func refreshVoiceAvailability() {
        let availability = ReadAlongAvailability.resolve(transcriber: transcriber)
        state.voiceAvailable = availability.voice || availability.voiceIsUnasked
    }

    // MARK: - Layout

    /// Re-reads the sheet's geometry. The editor calls it after a layout pass
    /// and after every text change.
    public func refreshLayout() {
        guard let host else { return }
        layouts = host.sentenceLayouts()
        reading.setLayout(layouts)
        if let diagnostics { updateDiagnostics(reading.state, in: diagnostics) }
    }

    /// The editor's scroll view moved under the user's finger.
    public func userDidScroll() {
        let time = clock.now
        scrollAssist.userDidScroll(at: time)
        driftCorrector.userDidScroll(at: time)
    }

    /// The sheet changed size. A big enough change invalidates the fit.
    public func viewDidResize(to size: CGSize) {
        driftCorrector.viewDidResize(to: size, calibration: calibration)
        refreshLayout()
    }

    /// Adopts a fresh fit and remembers its grade.
    public func apply(_ calibration: GazeAffineCalibration, verdict: CalibrationVerdict?) {
        self.calibration = calibration
        driftCorrector.reset()
        hasNagged = false
        filter.reset()
        if let verdict {
            state.calibrationGrade = verdict.grade
            settings.lastCalibrationGrade = verdict.grade.rawValue
        }
    }

    /// Re-reads the stored fit for the current orientation — after another
    /// screen calibrated, or after a rotation.
    public func reloadCalibration() {
        guard let stored = calibrationStore.calibration(for: interfaceOrientation) else { return }
        calibration = stored
        driftCorrector.reset()
        filter.reset()
    }

    private func refreshOrientedGeometry() {
        gate.screenSize = GazeScreenProjection.orientedSize(
            portraitSize: portraitScreenSize, orientation: interfaceOrientation)
        reloadCalibration()
        filter.reset()
    }

    // MARK: - Gaze

    public func gazeTracker(_ tracker: GazeTracking, didProduce sample: GazeSample) {
        ingest(sample, at: clock.now)
    }

    /// One camera frame. Public so the calibration screen and the tests can
    /// drive the same path the tracker does.
    public func ingest(_ sample: GazeSample, at time: TimeInterval) {
        guard state.isTracking, !isSuspended, let host else { return }

        var screenPoint: CGPoint?
        var faceTracked = true
        switch sample {
        case .point(let raw):
            let oriented = GazeScreenProjection.orientedScreenPoint(
                fromPortraitPoint: raw,
                portraitSize: portraitScreenSize,
                orientation: interfaceOrientation)
            screenPoint = filter.filter(calibration.point(from: oriented), at: time)
        case .offScreen:
            screenPoint = nil
        case .faceLost:
            faceTracked = false
        }

        var reason = gate.update(
            faceTracked: faceTracked, blinkLeft: 0, blinkRight: 0,
            point: screenPoint, at: time)
        if case .offScreen = sample { reason = .offScreen }
        lastGateReason = reason
        state.trackingLost = reason == .away

        if let screenPoint, reason == .ok {
            let container = ReadAlongGeometry.textContainerPoint(
                screenPoint: screenPoint,
                viewportOrigin: viewportOrigin(of: host),
                contentOffset: host.scrollView.contentOffset,
                textContainerOrigin: host.textContainerOrigin())
            lastGazePoint = container
            lastFixation = fixationDetector.ingest(container, at: time)
            reading.ingest(gaze: container, gate: reason, at: time)
        } else {
            lastGazePoint = nil
            reading.ingest(gaze: nil, gate: reason, at: time)
        }
    }

    /// The scroll view's origin on the DISPLAY. A window that does not fill
    /// the screen (Split View, Slide Over, Stage Manager) sits at a non-zero
    /// origin, so converting only to the window would be off by that much.
    private func viewportOrigin(of host: ReadAlongTextHosting) -> CGPoint {
        let scrollView = host.scrollView
        if let screen = scrollView.window?.screen {
            return scrollView.convert(CGPoint.zero, to: screen.coordinateSpace)
        }
        return scrollView.convert(CGPoint.zero, to: nil)
    }

    // MARK: - Frames

    public func readAlongDidTick(at time: TimeInterval) {
        guard isRunning, !isSuspended, let host else { return }
        let tracking = state.isTracking && lastGateReason == .ok
        if tracking {
            let reading = self.reading.tick(at: time)
            updateBandModel(reading)
            assistScroll(for: reading, at: time, in: host)
            correctDrift(for: reading, at: time)
        }
        layoutMirror(in: host)
        if let diagnostics {
            trace.record(at: time, gaze: lastGazePoint, gate: lastGateReason, state: reading.state)
            updateDiagnostics(reading.state, in: diagnostics)
        }
    }

    private func activeSentence(_ state: ReadingState) -> SentenceLayout? {
        guard let index = state.activeSentence, layouts.indices.contains(index)
        else { return nil }
        return layouts[index]
    }

    private func updateBandModel(_ state: ReadingState) {
        readingLayer.update(sentence: activeSentence(state), readUpToWord: state.readUpToWord)
    }

    /// Moves the mirror shapes every frame, gate open or not, so a scroll
    /// never slides the text out from under a frozen band.
    private func layoutMirror(in host: ReadAlongTextHosting) {
        let sentence = readingLayer.bandSentence.flatMap { index in
            layouts.indices.contains(index) ? layouts[index] : nil
        }
        readingLayer.layoutMirror(
            sentence: sentence,
            readUpToWord: reading.state.readUpToWord,
            offset: ReadAlongGeometry.hostOffset(
                contentOffset: host.scrollView.contentOffset,
                textContainerOrigin: host.textContainerOrigin()))
    }

    private func assistScroll(for state: ReadingState, at time: TimeInterval, in host: ReadAlongTextHosting) {
        guard let sentence = activeSentence(state) else { return }
        let scrollView = host.scrollView
        let centre = sentence.bounds.midY + host.textContainerOrigin().y
        let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        guard let delta = scrollAssist.adjustment(
            bandCentreY: centre,
            contentOffsetY: scrollView.contentOffset.y,
            viewportHeight: scrollView.bounds.height,
            maximumOffsetY: maximum,
            at: time)
        else { return }
        scrollView.contentOffset.y += delta
    }

    private func correctDrift(for state: ReadingState, at time: TimeInterval) {
        let centre = activeSentence(state).map { $0.bounds.midY }
        if let correction = driftCorrector.update(
            at: time, gaze: lastGazePoint, bandCentreY: centre, state: state)
        {
            calibration.nudge(
                toward: correction.error, gain: correction.gain, axes: correction.axes)
        }
        guard driftCorrector.needsRecalibration, !hasNagged else { return }
        hasNagged = true
        delegate?.readAlongCoordinatorNeedsRecalibration(self)
    }

    // MARK: - Speech

    public func speechDidDetectOnset() {
        pendingAnchor = currentAnchor()
    }

    public func speechDidFinishUtterance(_ text: String) {
        var snapshot = pendingAnchor
        pendingAnchor = nil
        if let anchor = snapshot, clock.now - anchor.time > Self.anchorLifetime {
            snapshot = nil
        }
        guard let snapshot = snapshot ?? currentAnchor(),
              let command = VoiceCommandClassifier.classify(text)
        else { return }
        apply(command, at: snapshot, spoken: text)
    }

    /// The range an utterance beginning now belongs to.
    ///
    /// While gaze is steering it is the LINE around the cursor word — a spoken
    /// remark is about a line, not a word. With no usable gaze it falls back
    /// to the sentence nearest 45 % of the viewport, which is where a reader
    /// looking at the page mostly is.
    private func currentAnchor() -> SpokenAnchor? {
        guard let host, !layouts.isEmpty else { return nil }
        var range: NSRange?
        let model = reading.state
        if state.isTracking, lastGateReason == .ok, model.mode == .gaze,
           let index = model.activeSentence, let cursor = model.cursorWord,
           layouts.indices.contains(index)
        {
            let words = reading.lineRange(aroundWord: cursor, in: index)
            range = ReadAlongGeometry.textRange(ofWords: words, in: layouts[index])
        }
        if range == nil {
            let scrollView = host.scrollView
            range = ReadAlongGeometry.sentence(
                nearestViewportFraction: 0.45,
                in: layouts,
                contentOffsetY: scrollView.contentOffset.y,
                viewportHeight: scrollView.bounds.height,
                textContainerOriginY: host.textContainerOrigin().y)?.textRange
        }
        guard let range, range.length > 0 else { return nil }
        return SpokenAnchor(range: range, anchor: host.anchor(for: range), time: clock.now)
    }

    private func apply(_ command: VoiceCommand, at snapshot: SpokenAnchor, spoken: String) {
        guard let host else { return }
        switch command {
        case .needsWork: addAnnotation(kind: .needsWork, at: snapshot, noteID: nil)
        case .expand: addAnnotation(kind: .expand, at: snapshot, noteID: nil)
        case .cut: addAnnotation(kind: .cut, at: snapshot, noteID: nil)
        case .keep: addAnnotation(kind: .keep, at: snapshot, noteID: nil)
        case .comment(let text):
            guard let note = try? markStore.insertVoiceNote(
                text: text, anchor: snapshot.anchor) else { return }
            addAnnotation(kind: .comment, at: snapshot, noteID: note.id)
        }
        delegate?.readAlongCoordinator(self, didHear: spoken)
        LunaToast.show(L10n.string("WriterReadAlong_heard", spoken), in: host.hostView)
    }

    private func addAnnotation(
        kind: Annotation.Kind, at snapshot: SpokenAnchor, noteID: NoteID?
    ) {
        let annotation = Annotation(
            documentID: documentID, kind: kind, source: .voice,
            noteID: noteID, anchor: snapshot.anchor)
        host?.addAnnotation(annotation)
        delegate?.readAlongCoordinator(self, didAdd: annotation)
    }

    // MARK: - Annotations

    /// The sheet's marks, as the open session holds them.
    public var annotations: [Annotation] { host?.storedAnnotations ?? [] }

    /// Removes every mark, and the notes their comments held.
    public func clearAnnotations() {
        guard let host else { return }
        for annotation in host.storedAnnotations {
            host.removeAnnotation(annotation.id)
            if let noteID = annotation.noteID { try? markStore.deleteNote(noteID) }
        }
    }

    // MARK: - Diagnostics

    public var isDiagnosticsVisible: Bool { diagnostics != nil }

    /// Shows or hides the overlay that draws the gaze estimate over the text.
    /// The session trace records only while it is showing.
    public func setDiagnosticsVisible(_ visible: Bool) {
        guard visible else {
            diagnostics?.removeFromSuperview()
            diagnostics = nil
            return
        }
        guard diagnostics == nil, let host else { return }
        let view = ReadAlongDiagnosticsView(frame: host.hostView.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.hostView.addSubview(view)
        diagnostics = view
        updateDiagnostics(reading.state, in: view)
    }

    private func updateDiagnostics(_ state: ReadingState, in diagnostics: ReadAlongDiagnosticsView) {
        guard let host else { return }
        diagnostics.update(
            ReadAlongDiagnosticsSnapshot(
                gaze: lastGazePoint,
                fixation: lastFixation,
                gate: lastGateReason,
                reading: state,
                wordsPerMinute: reading.wordsPerMinute,
                grade: self.state.calibrationGrade,
                offset: ReadAlongGeometry.hostOffset(
                    contentOffset: host.scrollView.contentOffset,
                    textContainerOrigin: host.textContainerOrigin()),
                sentences: layouts,
                pointsPerDegree: pointsPerDegree))
    }

    /// The session trace as a file, offered through the system share sheet.
    public func exportTrace(from presenter: UIViewController) {
        guard let url = try? trace.writeTemporaryFile() else { return }
        LunaShareSheet.present(items: [url], from: presenter, anchor: nil)
    }
}
