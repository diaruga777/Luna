//
//  GazeTrackerDelegateTests.swift
//  LunaTests
//
//  `ARFaceGazeTracker` itself needs real ARKit hardware and cannot run here;
//  this pins the delegate contract it emits through — a second, optional
//  method carrying blink state, added without disturbing the Reader's
//  `GazeSample`-only delegate.
//

import CoreGraphics
import XCTest
@testable import LunaGaze

private final class StubTracker: GazeTracking {
    weak var delegate: GazeTrackingDelegate?
    private(set) var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
}

/// The shape of the Reader's RSVP delegate: only the original method.
private final class SampleOnlyDelegate: GazeTrackingDelegate {
    private(set) var samples: [GazeSample] = []
    func gazeTracker(_ tracker: GazeTracking, didProduce sample: GazeSample) {
        samples.append(sample)
    }
}

private final class FullDelegate: GazeTrackingDelegate {
    private(set) var samples: [GazeSample] = []
    private(set) var frames: [GazeFrame] = []
    func gazeTracker(_ tracker: GazeTracking, didProduce sample: GazeSample) {
        samples.append(sample)
    }
    func gazeTracker(_ tracker: GazeTracking, didProduce frame: GazeFrame) {
        frames.append(frame)
    }
}

final class GazeTrackerDelegateTests: XCTestCase {

    private let sample = GazeSample.point(CGPoint(x: 10, y: 20))
    private lazy var frame = GazeFrame(
        sample: sample, blinkLeft: 0.9, blinkRight: 0.1, isFaceTracked: true)

    func testADelegateImplementingOnlyGazeSampleCompilesAndKeepsWorking() {
        let delegate = SampleOnlyDelegate()
        let tracker = StubTracker()
        tracker.delegate = delegate

        delegate.gazeTracker(tracker, didProduce: sample)
        // The default extension makes this a legal, harmless no-op for a
        // delegate that never opted into blink.
        delegate.gazeTracker(tracker, didProduce: frame)

        XCTAssertEqual(delegate.samples, [sample], "GazeSample delivery must be unchanged")
    }

    func testADelegateThatOptsInReceivesTheBlinkStateAlongsideTheSample() {
        let delegate = FullDelegate()
        let tracker = StubTracker()
        tracker.delegate = delegate

        delegate.gazeTracker(tracker, didProduce: sample)
        delegate.gazeTracker(tracker, didProduce: frame)

        XCTAssertEqual(delegate.samples, [sample])
        XCTAssertEqual(delegate.frames, [frame])
        XCTAssertEqual(delegate.frames.first?.blinkLeft, 0.9)
        XCTAssertEqual(delegate.frames.first?.blinkRight, 0.1)
        XCTAssertTrue(delegate.frames.first?.isFaceTracked ?? false)
    }
}
