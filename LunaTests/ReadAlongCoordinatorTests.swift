//
//  ReadAlongCoordinatorTests.swift
//  LunaTests
//

import CoreGraphics
import Foundation
import XCTest
@testable import LunaGaze
import LunaWriterModels
import LunaWriterStorage
@testable import LunaWriterReadAlong

final class ReadAlongCoordinatorTests: XCTestCase {

    // MARK: - The anchor is taken at onset

    func testOnsetAnchorsTheUtteranceToTheLineBeingReadNotTheOneReachedLater() {
        let session = makeReadAlongSession()
        let firstLine = session.sheet.centre(sentence: 0, word: 1)
        var time = session.look(at: firstLine, frames: 20, from: 0)

        let cursorAtOnset = session.coordinator.readingState.cursorWord
        XCTAssertEqual(session.coordinator.readingState.mode, .gaze)
        XCTAssertNotNil(cursorAtOnset)
        XCTAssertLessThan(cursorAtOnset!, SyntheticSheet.wordsPerLine)

        session.transcriber.onset()

        // The eyes move on to the second line while the sentence is spoken.
        let secondLine = session.sheet.centre(sentence: 0, word: 4)
        time = session.look(at: secondLine, frames: 60, from: time)
        XCTAssertGreaterThanOrEqual(
            session.coordinator.readingState.cursorWord ?? 0, SyntheticSheet.wordsPerLine,
            "the sweep must have left the first line, or the test proves nothing")

        session.transcriber.utterance("cut")

        let annotations = session.storedAnnotations
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations.first?.kind, .cut)
        XCTAssertEqual(annotations.first?.source, .voice)
        XCTAssertEqual(
            annotations.first?.anchor.range,
            session.sheet.lineRange(sentence: 0, word: 1),
            "the mark belongs to the line that was being read when speech began")
        _ = time
    }

    func testAnUtteranceWithNoGazeAnchorsToTheSentenceNearTheMiddleOfTheViewport() {
        let session = makeReadAlongSession(sentenceCount: 40, gazeEnabled: false)
        session.host.scrollView.contentOffset.y = 300

        session.transcriber.onset()
        session.transcriber.utterance("expand")

        // 45 % of a 700-point viewport scrolled to 300 is content y 615, which
        // is sentence 5's band.
        let expected = session.sheet.sentences[5].textRange
        XCTAssertEqual(session.storedAnnotations.first?.anchor.range, expected)
        XCTAssertEqual(session.storedAnnotations.first?.kind, .expand)
    }

    // MARK: - Classification

    func testEachCommandPhraseMakesItsOwnKindOfMark() {
        let cases: [(String, Annotation.Kind)] = [
            ("needs work", .needsWork),
            ("expand", .expand),
            ("cut", .cut),
            ("perfect", .keep),
        ]
        for (phrase, kind) in cases {
            let session = makeReadAlongSession(gazeEnabled: false)
            session.transcriber.onset()
            session.transcriber.utterance(phrase)
            XCTAssertEqual(
                session.storedAnnotations.first?.kind, kind, "\(phrase) should mark \(kind)")
            XCTAssertTrue(session.notes.stored.isEmpty, "a command is not a note")
        }
    }

    func testAFreeFormUtteranceBecomesAVoiceNoteAttachedToTheSheet() {
        let session = makeReadAlongSession(gazeEnabled: false)
        session.transcriber.onset()
        session.transcriber.utterance("the villain arrives far too late in this chapter")

        guard let annotation = session.storedAnnotations.first else {
            return XCTFail("no annotation was stored")
        }
        XCTAssertEqual(annotation.kind, .comment)
        XCTAssertEqual(annotation.source, .voice)

        guard let noteID = annotation.noteID, let note = session.notes.stored[noteID] else {
            return XCTFail("the comment carries no note")
        }
        XCTAssertEqual(note.source, .voice)
        XCTAssertEqual(note.text, "the villain arrives far too late in this chapter")
        XCTAssertEqual(note.anchor?.range, annotation.anchor.range)
        XCTAssertEqual(
            session.notes.attachments[noteID]?[session.documentID],
            NoteAttachment.voice,
            "the join must say the note arrived by voice")
    }

    func testAnUtteranceWithNothingSpokenInItStoresNothing() {
        let session = makeReadAlongSession(gazeEnabled: false)
        session.transcriber.onset()
        session.transcriber.utterance("  ...  ")
        XCTAssertTrue(session.storedAnnotations.isEmpty)
        XCTAssertTrue(session.notes.stored.isEmpty)
    }

    // MARK: - The gate

    func testTheBandStopsMovingWhileTheFaceIsGone() {
        let session = makeReadAlongSession()
        var time = session.look(
            at: session.sheet.centre(sentence: 0, word: 1), frames: 20, from: 0)
        XCTAssertNotNil(session.coordinator.readingLayer.bandRange)

        // The face-lost delay is 350 ms, so the gate only closes part way
        // through this run; the spy watches what happens AFTER it has.
        time = session.look(at: nil, frames: 40, from: time)
        XCTAssertEqual(session.coordinator.lastGateReason, .away)

        let spy = RenderingInvalidationSpy()
        session.coordinator.readingLayer.invalidationDelegate = spy
        time = session.look(at: nil, frames: 40, from: time)

        XCTAssertTrue(session.coordinator.state.trackingLost)
        XCTAssertEqual(
            spy.count, 0,
            "a lost face must freeze the band rather than let it drift")
        _ = time
    }

    func testTheBandMovesAgainOnceTheFaceComesBack() {
        let session = makeReadAlongSession()
        var time = session.look(
            at: session.sheet.centre(sentence: 0, word: 1), frames: 20, from: 0)
        time = session.look(at: nil, frames: 40, from: time)

        let spy = RenderingInvalidationSpy()
        session.coordinator.readingLayer.invalidationDelegate = spy
        _ = session.look(at: session.sheet.centre(sentence: 0, word: 1), frames: 10, from: time)

        XCTAssertEqual(session.coordinator.lastGateReason, .ok)
        XCTAssertFalse(session.coordinator.state.trackingLost)
        XCTAssertGreaterThan(spy.count, 0)
    }

    // MARK: - Scroll assist

    func testScrollAssistStandsDownForOnePointFourSecondsAfterAUserScroll() {
        // The sheet's first sentence sits low in the content, so the assist
        // has something it wants to do on every frame.
        let session = makeReadAlongSession(topInset: 600)
        let gaze = session.sheet.centre(sentence: 0, word: 1)
        var time = session.look(at: gaze, frames: 20, from: 0)
        XCTAssertGreaterThan(
            session.host.scrollView.contentOffset.y, 0,
            "the assist should be moving the page before the user touches it")

        session.host.scrollView.contentOffset.y = 0
        session.clock.now = time
        session.coordinator.userDidScroll()

        time = session.look(at: gaze, frames: 60, from: time)
        XCTAssertEqual(
            session.host.scrollView.contentOffset.y, 0,
            "the assist must not fight the user inside the settle window")

        time += 0.6
        _ = session.look(at: gaze, frames: 6, from: time)
        XCTAssertGreaterThan(
            session.host.scrollView.contentOffset.y, 0,
            "once the scroll has settled the assist resumes")
    }

    func testScrollAssistNeverMovesMoreThanOneStepInAFrame() {
        let session = makeReadAlongSession(topInset: 600)
        let gaze = session.sheet.centre(sentence: 0, word: 1)
        session.look(at: gaze, frames: 2, from: 0)
        XCTAssertLessThanOrEqual(
            session.host.scrollView.contentOffset.y,
            ScrollAssist.Configuration().maximumStep * 2)
    }

    // MARK: - Session shape

    func testStartInstallsBothLayersAndStopRemovesThem() {
        let session = makeReadAlongSession()
        XCTAssertEqual(session.host.installedLayers.count, 2)
        XCTAssertTrue(session.tracker.isRunning)
        XCTAssertTrue(session.transcriber.isRunning)

        session.coordinator.stop()

        XCTAssertEqual(session.host.removeCallCount, 1)
        XCTAssertFalse(session.tracker.isRunning)
        XCTAssertFalse(session.transcriber.isRunning)
        XCTAssertNil(session.coordinator.readingLayer.bandRange)
    }

    func testPausingTrackingStopsTheCameraAndKeepsTheUsersSetting() {
        let session = makeReadAlongSession()
        session.coordinator.togglePause()

        XCTAssertFalse(session.tracker.isRunning)
        XCTAssertTrue(session.coordinator.state.gazeEnabled)
        XCTAssertTrue(session.settings.gazeEnabled)
        XCTAssertEqual(session.coordinator.state.trackingIndicator, .busy)

        session.coordinator.togglePause()
        XCTAssertTrue(session.tracker.isRunning)
    }

    func testTurningGazeOffIsRememberedAndTurningItOnAsksForTheCamera() {
        let session = makeReadAlongSession()
        session.coordinator.setGazeEnabled(false)
        XCTAssertFalse(session.settings.gazeEnabled)
        XCTAssertFalse(session.tracker.isRunning)

        GazeTrackingPermission.statusOverride = .denied
        addTeardownBlock { GazeTrackingPermission.statusOverride = nil }
        session.coordinator.setGazeEnabled(true)
        XCTAssertFalse(
            session.settings.gazeEnabled, "a refused camera must not turn the feature on")

        GazeTrackingPermission.statusOverride = .granted
        session.coordinator.setGazeEnabled(true)
        XCTAssertTrue(session.settings.gazeEnabled)
        XCTAssertTrue(session.tracker.isRunning)
    }

    func testClearingAnnotationsRemovesTheMarksAndTheNotesTheirCommentsHeld() {
        let session = makeReadAlongSession(gazeEnabled: false)
        session.transcriber.onset()
        session.transcriber.utterance("this whole paragraph is doing two jobs at once")
        session.transcriber.onset()
        session.transcriber.utterance("cut")
        XCTAssertEqual(session.storedAnnotations.count, 2)
        XCTAssertEqual(session.notes.stored.count, 1)

        session.coordinator.clearAnnotations()

        XCTAssertTrue(session.storedAnnotations.isEmpty)
        XCTAssertTrue(session.notes.stored.isEmpty)
        XCTAssertTrue(session.coordinator.annotationLayer.annotations.isEmpty)
    }

    func testReloadingAnnotationsDropsAnAnchorWhoseTextIsGone() {
        let session = makeReadAlongSession(gazeEnabled: false)
        session.transcriber.onset()
        session.transcriber.utterance("keep")
        XCTAssertEqual(session.coordinator.annotationLayer.annotations.count, 1)

        var marks = try! session.marks.marks(for: session.documentID)
        marks.annotations = [
            Annotation(
                documentID: session.documentID, kind: .cut,
                anchor: TextAnchor(
                    start: 0, end: 16, exact: "words this sheet never contained")),
        ]
        try! session.marks.replaceMarks(marks, for: session.documentID)
        session.coordinator.reloadAnnotations()

        XCTAssertTrue(session.coordinator.annotationLayer.annotations.isEmpty)
    }

    // MARK: - Trace

    func testTheSessionTraceRecordsTheFramesTheModelSaw() {
        let session = makeReadAlongSession()
        session.look(at: session.sheet.centre(sentence: 0, word: 1), frames: 120, from: 0)

        let samples = session.coordinator.trace.samples
        XCTAssertGreaterThan(samples.count, 10)
        XCTAssertEqual(samples.first?.gate, GateReason.ok.rawValue)
        XCTAssertEqual(samples, samples.sorted { $0.time < $1.time })
    }
}
