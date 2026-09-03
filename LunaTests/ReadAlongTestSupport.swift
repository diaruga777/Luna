//
//  ReadAlongTestSupport.swift
//  LunaTests
//
//  A whole read-along session with no camera, no microphone, no window and no
//  clock: synthetic sentence geometry over real text, and hand-driven frames.
//

import CoreGraphics
import Foundation
import UIKit
import XCTest
@testable import LunaGaze
import LunaWriterModels
import LunaWriterStorage
import LunaWriterText
@testable import LunaWriterReadAlong
import LunaWriterVoice

// MARK: - Synthetic sheet

/// A sheet whose words are laid out on a grid, so a test can name the rect a
/// word occupies and the line it shares.
struct SyntheticSheet {

    /// Words per visual line.
    static let wordsPerLine = 3
    static let wordWidth: CGFloat = 60
    static let wordInset: CGFloat = 4
    static let lineHeight: CGFloat = 24
    /// Vertical distance between one sentence's top and the next's.
    static let sentenceStride: CGFloat = 120

    let text: NSString
    let sentences: [SentenceLayout]
    /// Where the first sentence's top sits in the text container.
    let topInset: CGFloat

    init(sentenceCount: Int, wordsPerSentence: Int = 6, topInset: CGFloat = 0) {
        self.topInset = topInset
        var body = ""
        var layouts: [SentenceLayout] = []
        for index in 0..<sentenceCount {
            let start = (body as NSString).length
            var words: [WordLayout] = []
            for word in 0..<wordsPerSentence {
                let token = "s\(index)w\(word)"
                let location = (body as NSString).length + (body.isEmpty ? 0 : 0)
                body += token
                let line = word / Self.wordsPerLine
                let column = word % Self.wordsPerLine
                let rect = CGRect(
                    x: CGFloat(column) * Self.wordWidth,
                    y: topInset + CGFloat(index) * Self.sentenceStride
                        + CGFloat(line) * Self.lineHeight,
                    width: Self.wordWidth - Self.wordInset,
                    height: Self.lineHeight - 4)
                words.append(
                    WordLayout(
                        textRange: NSRange(
                            location: location, length: (token as NSString).length),
                        rect: rect))
                body += word == wordsPerSentence - 1 ? ". " : " "
            }
            let end = (body as NSString).length
            let lineCount = (wordsPerSentence + Self.wordsPerLine - 1) / Self.wordsPerLine
            let lineRects = (0..<lineCount).map { line in
                CGRect(
                    x: 0,
                    y: topInset + CGFloat(index) * Self.sentenceStride
                        + CGFloat(line) * Self.lineHeight,
                    width: CGFloat(Self.wordsPerLine) * Self.wordWidth,
                    height: Self.lineHeight)
            }
            layouts.append(
                SentenceLayout(
                    index: index,
                    textRange: NSRange(location: start, length: end - start),
                    lineRects: lineRects,
                    words: words))
        }
        self.text = body as NSString
        self.sentences = layouts
    }

    /// The centre of one word, in text-container coordinates.
    func centre(sentence: Int, word: Int) -> CGPoint {
        sentences[sentence].words[word].centre
    }

    /// The text range every word on `word`'s line covers.
    func lineRange(sentence: Int, word: Int) -> NSRange {
        let layout = sentences[sentence]
        let words = layout.lineRange(around: word)
        return ReadAlongGeometry.textRange(ofWords: words, in: layout)!
    }
}

// MARK: - Host

/// A text host with real UIKit scroll geometry and no window.
final class FakeReadAlongHost: ReadAlongTextHosting {

    let sheet: SyntheticSheet
    let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    var containerOrigin = CGPoint.zero
    private(set) var installedLayers: [ReadAlongRenderingLayer] = []
    private(set) var removeCallCount = 0
    /// The marks the open session would hold, oldest first.
    private(set) var annotations: [Annotation] = []
    /// The window the scroll view reports, for a test that needs a non-zero
    /// viewport origin; nil keeps the window-less default.
    var window: UIWindow?

    init(sheet: SyntheticSheet, contentHeight: CGFloat = 4000) {
        self.sheet = sheet
        scrollView.contentSize = CGSize(width: 390, height: contentHeight)
    }

    func sentenceLayouts() -> [SentenceLayout] { sheet.sentences }
    func textContainerOrigin() -> CGPoint { containerOrigin }
    func installOverlayLayer(_ layer: ReadAlongRenderingLayer) { installedLayers.append(layer) }
    func removeOverlayLayer() {
        installedLayers.removeAll()
        removeCallCount += 1
    }
    func anchor(for range: NSRange) -> TextAnchor {
        TextAnchorResolver.make(range: range, in: sheet.text)
    }
    func range(for anchor: TextAnchor) -> NSRange? {
        TextAnchorResolver.resolve(anchor, in: sheet.text)
    }
    var textLength: Int { sheet.text.length }

    var storedAnnotations: [Annotation] { annotations }
    func addAnnotation(_ annotation: Annotation) { annotations.append(annotation) }
    func updateAnnotation(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }
    func removeAnnotation(_ id: AnnotationID) { annotations.removeAll { $0.id == id } }
}

// MARK: - Sources

final class FakeGazeTracker: GazeTracking {
    weak var delegate: GazeTrackingDelegate?
    private(set) var isRunning = false
    private(set) var startCount = 0

    func start() {
        isRunning = true
        startCount += 1
    }

    func stop() { isRunning = false }

    /// Publishes one sample the way `ARFaceGazeTracker` does.
    func emit(_ sample: GazeSample) {
        delegate?.gazeTracker(self, didProduce: sample)
    }
}

final class FakeSpeechTranscriber: SpeechTranscribing {
    weak var delegate: SpeechTranscribingDelegate?
    var isAvailable = true
    var unavailabilityReason: SpeechUnavailability?
    var startError: SpeechTranscribingError?
    private(set) var isRunning = false

    func start() throws {
        if let startError { throw startError }
        isRunning = true
    }

    func stop() { isRunning = false }

    func onset() { delegate?.speechDidDetectOnset() }
    func utterance(_ text: String) { delegate?.speechDidFinishUtterance(text) }
}

final class ManualTicker: ReadAlongTicking {
    weak var target: ReadAlongTickReceiving?
    private(set) var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
    func fire(at time: TimeInterval) { target?.readAlongDidTick(at: time) }
}

final class ManualClock: ReadAlongClock {
    var now: TimeInterval = 0
}

// MARK: - Stores

final class InMemoryDocumentMarks: DocumentMarksStoring {
    var stored: [DocumentID: DocumentMarks] = [:]
    private(set) var writeCount = 0

    func marks(for document: DocumentID) throws -> DocumentMarks {
        stored[document] ?? .empty
    }

    func replaceMarks(_ marks: DocumentMarks, for document: DocumentID) throws {
        stored[document] = marks
        writeCount += 1
    }
}

final class InMemoryNotes: NoteStoring {
    private(set) var stored: [NoteID: WriterNote] = [:]
    private(set) var attachments: [NoteID: [DocumentID: NoteAttachment]] = [:]

    func notes(for document: DocumentID) throws -> [WriterNote] {
        stored.values.filter { $0.documentIDs.contains(document) }
    }

    func unattachedNotes() throws -> [WriterNote] {
        stored.values.filter { $0.documentIDs.isEmpty }
    }

    func note(_ id: NoteID) throws -> WriterNote? { stored[id] }
    func insert(_ note: WriterNote) throws { stored[note.id] = note }
    func update(_ note: WriterNote) throws { stored[note.id] = note }

    func delete(_ id: NoteID) throws {
        stored[id] = nil
        attachments[id] = nil
    }

    func attach(
        _ id: NoteID, to document: DocumentID,
        attachment: NoteAttachment
    ) throws {
        attachments[id, default: [:]][document] = attachment
    }

    func detach(_ id: NoteID, from document: DocumentID) throws {
        attachments[id]?[document] = nil
    }
}

/// Counts the invalidations a rendering layer reports.
final class RenderingInvalidationSpy: ReadAlongRenderingLayerInvalidating {
    private(set) var ranges: [NSRange] = []
    var count: Int { ranges.count }

    func renderingLayer(_ layer: ReadAlongRenderingLayer, didInvalidate range: NSRange) {
        ranges.append(range)
    }
}

// MARK: - Session

/// One assembled session, and the handles a test drives it by.
struct ReadAlongTestSession {
    let coordinator: ReadAlongCoordinator
    let host: FakeReadAlongHost
    let tracker: FakeGazeTracker
    let transcriber: FakeSpeechTranscriber
    let notes: InMemoryNotes
    let ticker: ManualTicker
    let clock: ManualClock
    let settings: WriterSettings
    let documentID: DocumentID
    let sheet: SyntheticSheet

    /// The annotations the session has written into the host, oldest first.
    var storedAnnotations: [Annotation] { host.annotations }

    /// Feeds one frame and one tick at `time`, the way a live session does.
    ///
    /// `gaze` is a point in the TEXT CONTAINER — the word the reader is
    /// looking at — so a page the assist scrolls keeps the eyes on the same
    /// words rather than on the same pixels.
    func frame(gaze: CGPoint?, at time: TimeInterval) {
        clock.now = time
        let offset = ReadAlongGeometry.hostOffset(
            contentOffset: host.scrollView.contentOffset,
            textContainerOrigin: host.textContainerOrigin())
        let screen = gaze.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        tracker.emit(screen.map { GazeSample.point($0) } ?? .faceLost)
        ticker.fire(at: time)
    }

    /// Feeds `count` frames at 60 Hz starting at `start`, all looking at
    /// `gaze`. Returns the time after the last one.
    @discardableResult
    func look(at gaze: CGPoint?, frames count: Int, from start: TimeInterval) -> TimeInterval {
        var time = start
        for _ in 0..<count {
            frame(gaze: gaze, at: time)
            time += 1.0 / 60
        }
        return time
    }
}

extension XCTestCase {

    /// Builds a session on its own defaults suite, with gaze and voice already
    /// on — the durable half of `ReadAlongState` is not what a coordinator
    /// test is measuring.
    func makeReadAlongSession(
        sentenceCount: Int = 8,
        wordsPerSentence: Int = 6,
        topInset: CGFloat = 0,
        contentHeight: CGFloat = 4000,
        gazeEnabled: Bool = true,
        voiceEnabled: Bool = true,
        screenSize: CGSize = CGSize(width: 390, height: 700),
        orientation: UIInterfaceOrientation = .portrait
    ) -> ReadAlongTestSession {
        GazeTrackingAvailability.supportOverride = true
        addTeardownBlock { GazeTrackingAvailability.supportOverride = nil }

        let suiteName = "luna.readalong.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        let settings = WriterSettings(defaults: defaults, center: NotificationCenter())
        settings.gazeEnabled = gazeEnabled
        settings.voiceEnabled = voiceEnabled

        let sheet = SyntheticSheet(
            sentenceCount: sentenceCount, wordsPerSentence: wordsPerSentence,
            topInset: topInset)
        let host = FakeReadAlongHost(sheet: sheet, contentHeight: contentHeight)
        let tracker = FakeGazeTracker()
        let transcriber = FakeSpeechTranscriber()
        let notes = InMemoryNotes()
        let ticker = ManualTicker()
        let clock = ManualClock()
        let documentID = DocumentID()

        let coordinator = ReadAlongCoordinator(
            documentID: documentID,
            host: host,
            notes: notes,
            settings: settings,
            gazeTracker: tracker,
            transcriber: transcriber,
            calibrationStore: GazeCalibrationStore(
                defaults: defaults, key: "luna.readalong.tests.calibration"),
            ticker: ticker,
            clock: clock,
            screenSize: screenSize,
            idiom: .phone)
        coordinator.interfaceOrientation = orientation
        coordinator.start()

        return ReadAlongTestSession(
            coordinator: coordinator, host: host, tracker: tracker,
            transcriber: transcriber, notes: notes, ticker: ticker,
            clock: clock, settings: settings, documentID: documentID, sheet: sheet)
    }
}
