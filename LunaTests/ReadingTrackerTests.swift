//
//  ReadingTrackerTests.swift
//  LunaTests
//
//  The gazeread `sim.mjs` acceptance test, ported: a synthetic user whose eye
//  the pipeline has no model of is calibrated once with a still head, and then
//  moves. What must survive the move is the SENTENCE, not the word — so the
//  measure is a sentence band.
//

import CoreGraphics
import XCTest
@testable import LunaGaze

final class ReadingTrackerTests: XCTestCase {

    private let screenSize = CGSize(width: 393, height: 852)
    private lazy var pointsPerMetre = Double(GazeScreenProjection.pointsPerMetre(idiom: .phone))
    private lazy var pointsPerDegree = VisualAngle.pointsPerDegree(idiom: .phone)
    /// One sentence band: the height a line of prose plus its leading occupies,
    /// as an angle. gazeread's 50 px at a laptop is the same 1.05°.
    private lazy var band = 1.05 * pointsPerDegree

    private var basePose: SimHeadPose {
        SimHeadPose(eye: SIMD3(0.012, 0.020, -0.40), yaw: 0.02, pitch: -0.06)
    }

    private func makeUser() -> SimUser {
        SimUser(screenSize: screenSize, pointsPerMetre: pointsPerMetre, pose: basePose)
    }

    private func page() -> [SentenceLayout] {
        SimPage.make(wordCounts: [18, 24, 15, 21, 27, 16])
    }

    // MARK: - Calibration through the whole pipeline

    func testAPursuitSweepRecoversAnEyeThePipelineHasNoModelOf() {
        let user = makeUser()
        let identity = GazeAffineCalibration.identity(
            viewSize: screenSize, pointsPerDegree: pointsPerDegree)
        let before = SimCalibration.evaluate(identity, user: user, pose: basePose)
        XCTAssertGreaterThan(before.mean, band, "the raw estimate must start outside a band")

        let (fitted, collector) = SimCalibration.run(user: user, pointsPerDegree: pointsPerDegree)
        guard let calibration = fitted else { return XCTFail("no fit") }
        XCTAssertEqual(
            calibration.lag, SimCalibration.trueLag, accuracy: 0.001,
            "the lag search must find the lag the eye actually had")
        XCTAssertGreaterThan(collector.acceptedFrameCount, 100)

        let after = SimCalibration.evaluate(calibration, user: user, pose: basePose)
        XCTAssertLessThan(after.mean, band / 2, "a still head should land well inside a band")
        XCTAssertLessThan(after.mean, before.mean / 4)
    }

    func testTheVerdictGradesAGoodFitAsGood() {
        let user = makeUser()
        guard let calibration = SimCalibration.run(
            user: user, pointsPerDegree: pointsPerDegree).calibration
        else { return XCTFail("no fit") }
        var held: [CalibrationSample] = []
        for point in PursuitCalibrationPath.validationPoints(
            in: CGRect(origin: .zero, size: screenSize))
        {
            for _ in 0..<25 {
                guard let frame = user.frame(lookingAt: point) else { continue }
                held.append(CalibrationSample(raw: frame.raw, target: point))
            }
        }
        guard let verdict = calibration.validate(samples: held) else { return XCTFail("no verdict") }
        XCTAssertEqual(verdict.grade, .good)
        XCTAssertLessThan(verdict.degrees, 1.2)
    }

    // MARK: - Head pose deltas

    func testThePredictionStaysInsideASentenceBandWhenTheHeadMoves() {
        let user = makeUser()
        guard let calibration = SimCalibration.run(
            user: user, pointsPerDegree: pointsPerDegree).calibration
        else { return XCTFail("no fit") }

        // label, pose, vertical limit, overall limit
        let cases: [(String, SimHeadPose, CGFloat, CGFloat)] = [
            ("head dropped 30 mm", basePose.moved(y: -0.030), band, band * 1.2),
            ("head receded 50 mm", basePose.moved(z: -0.050), band, band),
            ("slouch: down 60, back 80, right 12",
             basePose.moved(x: 0.012, y: -0.060, z: -0.080), band * 1.6, band * 1.6),
            ("head yaw +10 degrees", basePose.turned(yaw: 0.17), band * 1.5, band * 1.5),
            ("head pitch -8 degrees", basePose.turned(pitch: -0.14), band * 1.5, band * 1.5),
        ]
        for (label, pose, verticalLimit, meanLimit) in cases {
            let measured = SimCalibration.evaluate(calibration, user: user, pose: pose)
            XCTAssertLessThan(measured.meanY, verticalLimit, "\(label): vertical error")
            XCTAssertLessThan(measured.mean, meanLimit, "\(label): overall error")
        }
    }

    func testTheTrackerFollowsTheReaderThroughAPageUnderEveryHeadPose() {
        let user = makeUser()
        guard let calibration = SimCalibration.run(
            user: user, pointsPerDegree: pointsPerDegree).calibration
        else { return XCTFail("no fit") }
        let sentences = page()

        let cases: [(String, SimHeadPose, Double, CGFloat)] = [
            ("still head", basePose, 0.95, band),
            ("head dropped 30 mm", basePose.moved(y: -0.030), 0.95, band),
            ("head receded 50 mm", basePose.moved(z: -0.050), 0.95, band),
            ("slouch", basePose.moved(x: 0.012, y: -0.060, z: -0.080), 0.90, band * 1.6),
            ("head yaw +10 degrees", basePose.turned(yaw: 0.17), 0.95, band),
            ("head pitch -8 degrees", basePose.turned(pitch: -0.14), 0.95, band * 1.5),
        ]
        for (label, pose, floor, bandLimit) in cases {
            let run = SimReadingRun.run(
                page: sentences, user: user, pose: pose, calibration: calibration,
                pointsPerDegree: pointsPerDegree)
            XCTAssertGreaterThan(run.scored, 800, "\(label): too little of the page was scored")
            XCTAssertGreaterThanOrEqual(
                run.withinOneFraction, floor,
                "\(label): tracked sentence strayed more than one band")
            XCTAssertGreaterThanOrEqual(
                run.minimumLead, 0,
                "\(label): the tracker must never fall behind the reader")
            XCTAssertLessThanOrEqual(run.maximumLead, 2, "\(label): ran too far ahead")
            XCTAssertLessThan(run.meanBandError, bandLimit, "\(label): vertical error")
            XCTAssertEqual(run.finalMode, .gaze, "\(label): the gaze should still be steering")
        }
    }

    /// Scoring is windowed to ±6 sentences around the tracker's current one
    /// (plus a generous vertical band pre-filter), rather than scanning the
    /// whole document every frame. Within the window the arithmetic is
    /// unchanged — the window only excludes candidates, it never touches the
    /// likelihood or the prior for a sentence it keeps — so a switch to a
    /// sentence sitting exactly on the window's edge must succeed exactly as
    /// it would from a full scan, in both directions.
    func testWindowedScoringFindsASwitchAtTheEdgeOfTheWindowInEitherDirection() {
        let sentences = SimPage.spaced(count: 14, words: 10)
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout(sentences)

        tracker.resetTo(sentence: 3)
        let forwardTarget = centre(of: sentences[9], word: 5) // delta = +6
        var time: TimeInterval = 0
        while time < 2.0 {
            tracker.ingest(gaze: forwardTarget, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        XCTAssertEqual(
            tracker.state.activeSentence, 9,
            "a sentence exactly six ahead must still win the switch")

        tracker.resetTo(sentence: 10)
        let backwardTarget = centre(of: sentences[4], word: 5) // delta = -6
        while time < 4.0 {
            tracker.ingest(gaze: backwardTarget, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        XCTAssertEqual(
            tracker.state.activeSentence, 4,
            "a sentence exactly six behind must still win the switch")
    }

    // MARK: - Switching

    private func spacedTracker() -> (ReadingTracker, [SentenceLayout]) {
        let sentences = SimPage.spaced()
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout(sentences)
        return (tracker, sentences)
    }

    private func centre(of sentence: SentenceLayout, word: Int) -> CGPoint {
        CGPoint(x: sentence.words[word].rect.midX, y: sentence.lineRects[0].midY)
    }

    func testASwitchWaitsOutTheDebounceBeforeItCommits() {
        let (tracker, sentences) = spacedTracker()
        let target = centre(of: sentences[1], word: 4)
        var committed: TimeInterval = -1
        var time: TimeInterval = 0
        while time < 1.2 {
            tracker.ingest(gaze: target, gate: .ok, at: time)
            let state = tracker.tick(at: time)
            if time < 0.47 {
                XCTAssertEqual(state.activeSentence, 0, "switched early at \(time)")
            }
            if committed < 0, state.activeSentence == 1 { committed = time }
            time += 1.0 / 60
        }
        XCTAssertEqual(committed, 0.48, accuracy: 1.0 / 30)
    }

    func testAGlanceShorterThanTheDebounceLeavesTheReaderWhereTheyWere() {
        let (tracker, sentences) = spacedTracker()
        let away = centre(of: sentences[1], word: 4)
        let home = centre(of: sentences[0], word: 4)
        var time: TimeInterval = 0
        while time < 0.30 {
            tracker.ingest(gaze: away, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        while time < 1.2 {
            tracker.ingest(gaze: home, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        XCTAssertEqual(tracker.state.activeSentence, 0)
    }

    // MARK: - Sweep

    func testAGazeDwellingOnAnEarlierWordSnapsTheCursorBack() {
        let sentences = SimPage.spaced(count: 3, words: 24)
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout(sentences)
        var time: TimeInterval = 0
        // Let the modelled sweep run ahead with no gaze at all.
        while time < 2.0 {
            tracker.ingest(gaze: nil, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        let ahead = tracker.state
        XCTAssertEqual(ahead.activeSentence, 0)
        XCTAssertGreaterThan(ahead.cursorWord ?? 0, 5, "the sweep must be well ahead to snap back")

        let back = centre(of: sentences[0], word: 0)
        var snapped: TimeInterval = -1
        while time < 4.5 {
            tracker.ingest(gaze: back, gate: .ok, at: time)
            let state = tracker.tick(at: time)
            if snapped < 0, state.activeSentence == 0, (state.cursorWord ?? 99) <= 2 {
                snapped = time - 2.0
            }
            time += 1.0 / 60
        }
        XCTAssertGreaterThan(snapped, 0.40, "the snap must wait out its dwell")
        XCTAssertLessThan(snapped, 1.2)
        XCTAssertEqual(tracker.state.activeSentence, 0)
    }

    func testTheSweepMovesOnByItselfWhenThereIsNoGazeAtAll() {
        let sentences = SimPage.spaced(count: 5, words: 8)
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout(sentences)
        var advances: [TimeInterval] = []
        var previous = 0
        var time: TimeInterval = 0
        while time < 12 {
            tracker.ingest(gaze: nil, gate: .ok, at: time)
            let state = tracker.tick(at: time)
            if let active = state.activeSentence, active != previous {
                advances.append(time)
                previous = active
            }
            time += 1.0 / 60
        }
        XCTAssertEqual(tracker.state.mode, .auto)
        XCTAssertEqual(advances.count, 4, "five sentences means four hand-overs")
        // Eight words at the initial 230 wpm, plus the auto-mode stall.
        let expected = 8.0 / (230.0 / 60) + 0.26
        XCTAssertEqual(advances[0], expected, accuracy: 0.1)
        for index in 1..<advances.count {
            XCTAssertEqual(advances[index] - advances[index - 1], expected, accuracy: 0.1)
        }
    }

    func testAClosedGateFreezesTheHighlightWhereItIs() {
        let sentences = SimPage.spaced(count: 5, words: 8)
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout(sentences)
        var time: TimeInterval = 0
        while time < 1.0 {
            tracker.ingest(gaze: nil, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        let frozen = tracker.state
        while time < 3.0 {
            tracker.ingest(gaze: nil, gate: .blink, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        XCTAssertEqual(tracker.state.cursorWord, frozen.cursorWord)
        XCTAssertEqual(tracker.state.activeSentence, frozen.activeSentence)
    }

    // MARK: - Quality

    func testTheModeDropsToAutoOnlyAfterTheSignalHasBeenBadForLongEnough() {
        let sentences = SimPage.spaced(count: 5, words: 8)
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout(sentences)
        let onText = centre(of: sentences[0], word: 3)
        var time: TimeInterval = 0
        while time < 2.0 {
            tracker.ingest(gaze: onText, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        XCTAssertEqual(tracker.state.mode, .gaze)
        XCTAssertGreaterThan(tracker.state.quality, 0.9)

        let left = time
        var dropped: TimeInterval = -1
        let offThePage = CGPoint(x: 3000, y: 6000)
        while time < 12 {
            tracker.ingest(gaze: offThePage, gate: .ok, at: time)
            let state = tracker.tick(at: time)
            if dropped < 0, state.mode == .auto { dropped = time - left }
            time += 1.0 / 60
        }
        XCTAssertGreaterThan(dropped, 2.5, "the drop must wait out its delay")
        XCTAssertLessThan(dropped, 3.3)
        XCTAssertLessThan(tracker.state.quality, 0.22)
    }

    func testResidualRisesWhenTheGazeSitsAwayFromTheActiveSentence() {
        let sentences = SimPage.spaced(count: 3, words: 12)
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout(sentences)
        let onText = centre(of: sentences[0], word: 3)
        var time: TimeInterval = 0
        while time < 1.0 {
            tracker.ingest(gaze: onText, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        XCTAssertLessThan(tracker.state.residual, 5)
        let low = CGPoint(x: onText.x, y: onText.y + 120)
        while time < 3.0 {
            tracker.ingest(gaze: low, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        XCTAssertGreaterThan(tracker.state.residual, 40)
    }

    /// A residual run up while gaze is present must decay, not freeze, once
    /// gaze is lost — a frozen number would go on tripping the recalibration
    /// nag for as long as the reader's face is out of frame, over a value
    /// that no longer measures anything current.
    func testResidualDecaysRatherThanFreezingWhileGazeIsLost() {
        let sentences = SimPage.spaced(count: 3, words: 12)
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout(sentences)
        let onText = centre(of: sentences[0], word: 3)
        var time: TimeInterval = 0
        while time < 1.0 {
            tracker.ingest(gaze: onText, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        let low = CGPoint(x: onText.x, y: onText.y + 120)
        while time < 3.0 {
            tracker.ingest(gaze: low, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        let peak = tracker.state.residual
        XCTAssertGreaterThan(peak, 40, "the setup must actually raise the residual first")

        while time < 5.0 {
            tracker.ingest(gaze: nil, gate: .away, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        XCTAssertLessThan(tracker.state.residual, peak / 2, "the residual must decay while gaze is lost")
    }

    // MARK: - Layout questions

    func testLineRangeIsEveryWordSharingAVisualLine() {
        let sentences = SimPage.make(wordCounts: [20])
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout(sentences)
        let first = tracker.lineRange(aroundWord: 0, in: 0)
        XCTAssertEqual(first.lowerBound, 0)
        XCTAssertGreaterThan(first.count, 1)
        XCTAssertLessThan(first.count, sentences[0].wordCount)
        // Every word in the range shares the anchor's line, and the neighbours
        // outside it do not.
        let anchorY = sentences[0].words[0].rect.midY
        for index in first {
            XCTAssertEqual(sentences[0].words[index].rect.midY, anchorY, accuracy: 0.001)
        }
        XCTAssertNotEqual(sentences[0].words[first.upperBound].rect.midY, anchorY)
        // A word in the middle gives its own line, not the first.
        let middle = tracker.lineRange(aroundWord: first.upperBound, in: 0)
        XCTAssertEqual(middle.lowerBound, first.upperBound)
        XCTAssertEqual(tracker.lineRange(aroundWord: 0, in: 99), 0..<0)
    }

    /// A re-wrap keeps the sentence index but must forget the sweep inside
    /// it — the old word offset belongs to geometry that no longer exists.
    func testSetLayoutResetsTheSweepButKeepsTheSentenceIndex() {
        let sentences = SimPage.make(wordCounts: [20, 20])
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout(sentences)

        // Auto-mode sweep with no gaze at all still advances `progress`.
        var time: TimeInterval = 0
        while time < 2.0 {
            tracker.ingest(gaze: nil, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        XCTAssertGreaterThan(tracker.state.cursorWord ?? 0, 0, "the sweep must have moved")
        XCTAssertEqual(tracker.state.activeSentence, 0)

        // A re-wrap that keeps the same sentence count re-lays the same page.
        tracker.setLayout(sentences)
        XCTAssertEqual(tracker.state.activeSentence, 0, "the sentence index survives")
        XCTAssertEqual(tracker.state.cursorWord, 0, "the sweep inside it does not")
        XCTAssertEqual(tracker.state.readUpToWord, -1)
    }

    func testResetToPutsTheReaderAtTheStartOfASentence() {
        let sentences = SimPage.spaced(count: 5, words: 8)
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout(sentences)
        var time: TimeInterval = 0
        while time < 6 {
            tracker.ingest(gaze: nil, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        XCTAssertGreaterThan(tracker.state.activeSentence ?? 0, 0)
        tracker.resetTo(sentence: 1)
        XCTAssertEqual(tracker.state.activeSentence, 1)
        XCTAssertEqual(tracker.state.cursorWord, 0)
        XCTAssertEqual(tracker.state.readUpToWord, -1)
        tracker.resetTo(sentence: 99)
        XCTAssertEqual(tracker.state.activeSentence, 4, "an index past the end lands on the last")
    }

    func testAnEmptyLayoutHasNoActiveSentence() {
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout([])
        tracker.ingest(gaze: CGPoint(x: 10, y: 10), gate: .ok, at: 0)
        XCTAssertNil(tracker.tick(at: 0.1).activeSentence)
    }

    func testTheReadingSpeedIsLearnedAndStaysInsideItsBounds() {
        let user = makeUser()
        guard let calibration = SimCalibration.run(
            user: user, pointsPerDegree: pointsPerDegree).calibration
        else { return XCTFail("no fit") }
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        let sentences = page()
        tracker.setLayout(sentences)
        var euro = OneEuroFilter()
        let fixations = FixationDetector(pointsPerDegree: pointsPerDegree)
        var time: TimeInterval = 0
        while let truth = SimPage.position(in: sentences, at: time, wordsPerMinute: 300) {
            let word = sentences[truth.sentence].words[truth.word].rect
            var gaze: CGPoint?
            if let frame = user.frame(lookingAt: CGPoint(x: word.midX, y: word.midY)) {
                let smoothed = euro.filter(calibration.point(from: frame.raw), at: time)
                fixations.ingest(smoothed, at: time)
                gaze = fixations.fixation?.point
            }
            tracker.ingest(gaze: gaze, gate: .ok, at: time)
            tracker.tick(at: time)
            time += 1.0 / 60
        }
        XCTAssertNotEqual(tracker.wordsPerMinute, 230, accuracy: 0.001)
        XCTAssertTrue((120.0...520.0).contains(tracker.wordsPerMinute))
    }
}
