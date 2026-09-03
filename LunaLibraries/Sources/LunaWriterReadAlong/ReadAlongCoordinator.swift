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
public final class ReadAlongCoordinator: NSObject, GazeTrackingDelegate,
                                         SpeechTranscribingDelegate, ReadAlongTickReceiving {

    // MARK: - Collaborators

    public weak var delegate: ReadAlongCoordinatorDelegate?

    public let documentID: DocumentID
    public let readingLayer = ReadingLayer()
    public let annotationLayer = AnnotationLayer()
    public let trace = SessionTrace()
    public let markStore: ReadAlongMarkStore

    private let host: ReadAlongTextHosting
    private let settings: WriterSettings
    private let gazeTracker: GazeTracking
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
    /// The reading model's own view of the sheet.
    public var readingState: ReadingState { reading.state }
    public private(set) var lastGateReason: GateReason = .away
    /// The last calibrated gaze, in text-container coordinates.
    public private(set) var lastGazePoint: CGPoint?
    public private(set) var lastFixation: Fixation?
    public private(set) var layouts: [SentenceLayout] = []

    /// The display's size held upright, for rotating a portrait-origin sample.
    public var portraitScreenSize: CGSize
    /// The orientation the sheet is presented in.
    public var interfaceOrientation: UIInterfaceOrientation = .portrait
    public let pointsPerDegree: CGFloat

    private var pendingAnchor: SpokenAnchor?
    private var hasNagged = false
    private var diagnostics: ReadAlongDiagnosticsView?

    private struct SpokenAnchor {
        let range: NSRange
        let anchor: TextAnchor
    }

    // MARK: - Life cycle

    public init(
        documentID: DocumentID,
        host: ReadAlongTextHosting,
        marks: DocumentMarksStoring,
        notes: NoteStoring,
        settings: WriterSettings = WriterSettings(),
        gazeTracker: GazeTracking? = nil,
        transcriber: SpeechTranscribing? = nil,
        calibrationStore: GazeCalibrationStore = GazeCalibrationStore(),
        ticker: ReadAlongTicking = DisplayLinkTicker(),
        clock: ReadAlongClock = SystemReadAlongClock(),
        screenSize: CGSize = UIScreen.main.fixedCoordinateSpace.bounds.size,
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom
    ) {
        self.documentID = documentID
        self.host = host
        self.settings = settings
        self.markStore = ReadAlongMarkStore(documentID: documentID, marks: marks, notes: notes)
        self.gazeTracker = gazeTracker ?? ARFaceGazeTracker()
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
        self.calibration = calibrationStore.calibration(for: .portrait)
            ?? GazeAffineCalibration.identity(viewSize: screenSize, pointsPerDegree: perDegree)

        let availability = ReadAlongAvailability.resolve(transcriber: transcriber)
        self.state = ReadAlongState(
            gazeEnabled: settings.gazeEnabled,
            voiceEnabled: settings.voiceEnabled,
            gazeAvailable: availability.gaze,
            voiceAvailable: availability.voice,
            calibrationGrade: settings.lastCalibrationGrade
                .flatMap(CalibrationVerdict.Grade.init(rawValue:)))
        super.init()

        self.gazeTracker.delegate = self
        self.transcriber?.delegate = self
        self.ticker.target = self
    }

    deinit {
        gazeTracker.stop()
        transcriber?.stop()
        ticker.stop()
    }

    /// Installs the layers, reads the sheet's marks, and starts whichever
    /// halves the user has already turned on.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        host.installOverlayLayer(readingLayer)
        host.installOverlayLayer(annotationLayer)
        readingLayer.attach(to: host.hostView)
        refreshLayout()
        reloadAnnotations()
        ticker.start()
        applyGazeRunState()
        applyVoiceRunState()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        ticker.stop()
        gazeTracker.stop()
        transcriber?.stop()
        state.isListening = false
        readingLayer.detach()
        readingLayer.clear()
        host.removeOverlayLayer()
    }

    // MARK: - Toggles

    /// Turns gaze on or off. Camera authorization is asked HERE — at the
    /// moment the user opts in — and nowhere else.
    public func setGazeEnabled(_ enabled: Bool) {
        guard enabled != state.gazeEnabled else { return }
        guard enabled else {
            state.applyGazeToggle()
            settings.gazeEnabled = false
            applyGazeRunState()
            return
        }
        guard state.gazeAvailable else { return }
        GazeTrackingPermission.request { [weak self] status in
            guard let self else { return }
            guard status == .granted else {
                self.delegate?.readAlongCoordinator(self, didRefusePermissionFor: .gaze)
                return
            }
            self.state.applyGazeToggle()
            self.settings.gazeEnabled = self.state.gazeEnabled
            self.applyGazeRunState()
        }
    }

    /// Turns spoken comments on or off, asking for the microphone and speech
    /// recognition at the moment of opt-in.
    public func setVoiceEnabled(_ enabled: Bool) {
        guard enabled != state.voiceEnabled else { return }
        guard enabled else {
            state.applyVoiceToggle()
            settings.voiceEnabled = false
            applyVoiceRunState()
            return
        }
        guard state.voiceAvailable else { return }
        VoicePermissions.request { [weak self] status in
            guard let self else { return }
            guard status.isGranted else {
                self.delegate?.readAlongCoordinator(self, didRefusePermissionFor: .voice)
                return
            }
            self.state.applyVoiceToggle()
            self.settings.voiceEnabled = self.state.voiceEnabled
            self.applyVoiceRunState()
        }
    }

    /// Holds tracking without forgetting that the user wants it.
    public func togglePause() {
        state.applyPauseToggle()
        applyGazeRunState()
    }

    private func applyGazeRunState() {
        guard isRunning, state.isTracking else {
            gazeTracker.stop()
            readingLayer.clear()
            return
        }
        filter.reset()
        fixationDetector.reset()
        gate.reset()
        gazeTracker.start()
    }

    private func applyVoiceRunState() {
        guard isRunning, state.isVoiceActive else {
            transcriber?.stop()
            state.isListening = false
            return
        }
        do {
            try transcriber?.start()
            state.isListening = true
        } catch {
            state.isListening = false
            state.voiceAvailable = false
        }
    }

    // MARK: - Layout

    /// Re-reads the sheet's geometry. The editor calls it after a re-wrap.
    public func refreshLayout() {
        layouts = host.sentenceLayouts()
        reading.setLayout(layouts)
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
        gate.screenSize = size
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

    // MARK: - Gaze

    public func gazeTracker(_ tracker: GazeTracking, didProduce sample: GazeSample) {
        ingest(sample, at: clock.now)
    }

    /// One camera frame. Public so the calibration screen and the tests can
    /// drive the same path the tracker does.
    public func ingest(_ sample: GazeSample, at time: TimeInterval) {
        guard state.isTracking else { return }

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

        // `GazeTracking` reports no blend shapes, so the blink leg of the gate
        // cannot fire here; a closed eye reaches the model as an off-screen or
        // lost frame instead.
        var reason = gate.update(
            faceTracked: faceTracked, blinkLeft: 0, blinkRight: 0,
            point: screenPoint, at: time)
        if case .offScreen = sample { reason = .offScreen }
        lastGateReason = reason
        state.trackingLost = reason == .away

        if let screenPoint, reason == .ok {
            let container = ReadAlongGeometry.textContainerPoint(
                screenPoint: screenPoint,
                viewportOrigin: viewportOrigin,
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

    private var viewportOrigin: CGPoint {
        host.scrollView.convert(CGPoint.zero, to: nil)
    }

    // MARK: - Frames

    public func readAlongDidTick(at time: TimeInterval) {
        guard isRunning else { return }
        let reading = self.reading.tick(at: time)
        if lastGateReason == .ok { updateBand(reading) }
        assistScroll(for: reading, at: time)
        correctDrift(for: reading, at: time)
        trace.record(at: time, gaze: lastGazePoint, gate: lastGateReason, state: reading)
        updateDiagnostics(reading)
    }

    private func activeSentence(_ state: ReadingState) -> SentenceLayout? {
        guard let index = state.activeSentence, layouts.indices.contains(index)
        else { return nil }
        return layouts[index]
    }

    private func updateBand(_ state: ReadingState) {
        let sentence = activeSentence(state)
        readingLayer.update(sentence: sentence, readUpToWord: state.readUpToWord)
        readingLayer.layoutMirror(
            sentence: sentence,
            readUpToWord: state.readUpToWord,
            offset: ReadAlongGeometry.hostOffset(
                contentOffset: host.scrollView.contentOffset,
                textContainerOrigin: host.textContainerOrigin()))
    }

    private func assistScroll(for state: ReadingState, at time: TimeInterval) {
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
        onMain { self.pendingAnchor = self.currentAnchor() }
    }

    public func speechDidFinishUtterance(_ text: String) {
        onMain {
            let snapshot = self.pendingAnchor ?? self.currentAnchor()
            self.pendingAnchor = nil
            guard let snapshot, let command = VoiceCommandClassifier.classify(text) else { return }
            self.apply(command, at: snapshot, spoken: text)
        }
    }

    /// The range an utterance beginning now belongs to.
    ///
    /// While gaze is steering it is the LINE around the cursor word — a spoken
    /// remark is about a line, not a word. With no usable gaze it falls back
    /// to the sentence nearest 45 % of the viewport, which is where a reader
    /// looking at the page mostly is.
    private func currentAnchor() -> SpokenAnchor? {
        guard !layouts.isEmpty else { return nil }
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
        return SpokenAnchor(range: range, anchor: host.anchor(for: range))
    }

    private func apply(_ command: VoiceCommand, at snapshot: SpokenAnchor, spoken: String) {
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
        try? markStore.append(annotation)
        annotationLayer.add(
            ResolvedAnnotation(id: annotation.id, range: snapshot.range, kind: kind))
        delegate?.readAlongCoordinator(self, didAdd: annotation)
    }

    // MARK: - Annotations

    /// Reads the sheet's stored marks and resolves each anchor against the
    /// live text. An anchor whose quote is gone is dropped rather than drawn
    /// at the wrong place.
    public func reloadAnnotations() {
        guard let stored = try? markStore.annotations() else { return }
        let resolved = stored.compactMap { annotation -> ResolvedAnnotation? in
            guard let range = host.range(for: annotation.anchor), range.length > 0
            else { return nil }
            return ResolvedAnnotation(
                id: annotation.id, range: range, kind: annotation.kind)
        }
        annotationLayer.setAnnotations(resolved)
    }

    public func clearAnnotations() {
        try? markStore.removeAll()
        annotationLayer.removeAll()
    }

    // MARK: - Diagnostics

    public var isDiagnosticsVisible: Bool { diagnostics != nil }

    /// Shows or hides the overlay that draws the gaze estimate over the text.
    public func setDiagnosticsVisible(_ visible: Bool) {
        guard visible else {
            diagnostics?.removeFromSuperview()
            diagnostics = nil
            return
        }
        guard diagnostics == nil else { return }
        let view = ReadAlongDiagnosticsView(frame: host.hostView.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.hostView.addSubview(view)
        diagnostics = view
        updateDiagnostics(reading.state)
    }

    private func updateDiagnostics(_ state: ReadingState) {
        guard let diagnostics else { return }
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

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
