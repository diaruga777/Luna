//
//  ScrollDirectionImmersionTrackerTests.swift
//  LunaTests
//
//  ScrollDirectionImmersionTracker was extracted as the carousel host's generic
//  "is the user reading, or surfacing" signal (Wave 3B). These tests drive its
//  scroll-view path with synthetic contentOffset sequences — the RSVP
//  play-state path is a two-line passthrough not covered here, since
//  constructing a real RSVPViewController (audio engine, playback center) to
//  reach it isn't cheap.
//

import UIKit
import XCTest
@testable import Luna

final class ScrollDirectionImmersionTrackerTests: XCTestCase {

    /// `isDragging`/`isDecelerating` are read-only, gesture-driven state on a
    /// real `UIScrollView` — this subclass makes them test-settable so
    /// `contentOffset` writes can simulate a user drag deterministically.
    private final class FakeScrollView: UIScrollView {
        var fakeIsDragging = false
        var fakeIsDecelerating = false
        override var isDragging: Bool { fakeIsDragging }
        override var isDecelerating: Bool { fakeIsDecelerating }
    }

    private var container: UIViewController!
    private var scrollView: FakeScrollView!
    private var tracker: ScrollDirectionImmersionTracker!
    private var events: [(immersed: Bool, extendsCard: Bool)] = []

    override func setUp() {
        super.setUp()
        container = UIViewController()
        container.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        scrollView = FakeScrollView(frame: container.view.bounds)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentSize = CGSize(width: 400, height: 4000)
        container.view.addSubview(scrollView)

        tracker = ScrollDirectionImmersionTracker()
        tracker.bottomRevealDistance = { 0 }
        events = []
        tracker.onImmersionChange = { [weak self] immersed, extendsCard in
            self?.events.append((immersed, extendsCard))
        }
        tracker.observe(container)
        tracker.isActive = true
    }

    private func drag(to y: CGFloat) {
        scrollView.fakeIsDragging = true
        scrollView.contentOffset = CGPoint(x: 0, y: y)
    }

    // MARK: - Direction accumulation + fade-out threshold (scrolling down)

    func testFirstOffsetChangeOnlySeedsTheBaselineAndNeverFires() {
        drag(to: 5)
        XCTAssertTrue(events.isEmpty)
    }

    func testDownwardTravelBelowThresholdDoesNotFire() {
        drag(to: 0)
        drag(to: 10)
        drag(to: 20) // cumulative run 20 < fadeOutTravel (24)
        XCTAssertTrue(events.isEmpty)
    }

    func testDownwardTravelPastThresholdFiresImmersedTrue() {
        drag(to: 0)
        drag(to: 10)
        drag(to: 20)
        drag(to: 30) // cumulative run 30 >= 24
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.immersed, true)
        XCTAssertEqual(events.first?.extendsCard, true, "the scroll reader extends the card on immersion")
    }

    func testTravelAccumulatesAcrossMultipleSmallDeltasNotJustTheLastOne() {
        drag(to: 0)
        drag(to: 8)   // run 8
        drag(to: 16)  // run 16
        XCTAssertTrue(events.isEmpty, "16pt of accumulated travel hasn't crossed 24pt yet")
        drag(to: 26)  // run 26 >= 24
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.immersed, true)
    }

    // MARK: - A direction flip resets the run (jitter doesn't cross the threshold)

    func testADirectionFlipResetsTheAccumulatedRun() {
        drag(to: 0)
        drag(to: 15)  // run 15, downward
        drag(to: 10)  // flips upward: run resets to -5, not 15-5=10
        drag(to: 25)  // flips back downward: run resets to 15, still short of 24
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Fade-in threshold (scrolling up), one third of the viewport

    func testUpwardTravelPastThresholdFiresImmersedFalse() {
        drag(to: 600)
        drag(to: 450)  // run -150, below one third of the 800pt viewport
        XCTAssertTrue(events.isEmpty)
        drag(to: 320)  // run -280, beyond 800 / 3
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.immersed, false)
        XCTAssertEqual(events.first?.extendsCard, true)
    }

    func testTinyUpwardCorrectionDoesNotRestoreChrome() {
        drag(to: 600)
        drag(to: 588)
        drag(to: 560)
        XCTAssertTrue(events.isEmpty)
    }

    func testReachingTheTopAlwaysFiresImmersedFalseRegardlessOfRun() {
        // A single small upward step to position 0 doesn't cross fadeInTravel on
        // its own, but "at the top" is its own unconditional trigger.
        drag(to: 5)
        drag(to: 0)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.immersed, false)
    }

    func testArticleBottomRestoresAtFutureRestingCardEdge() {
        tracker.bottomRevealDistance = { 100 }
        // Positioning/restoration itself is not user motion and must not count
        // toward the directional threshold. Resume a real drag just outside
        // the future resting edge; maximum position is 3200.
        scrollView.fakeIsDragging = false
        scrollView.contentOffset = CGPoint(x: 0, y: 3000)
        drag(to: 3099) // seeds at 101pt remaining
        XCTAssertTrue(events.isEmpty)
        drag(to: 3100) // 100pt remains: content bottom meets that edge
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.immersed, false)
    }

    // MARK: - The re-entrancy guard

    func testSyntheticOffsetChangeDuringTheCallbackDoesNotDoubleFire() {
        // The fade's card-bottom extension resizes the scroll view synchronously,
        // which can clamp the offset and re-enter this same KVO path from inside
        // the callback. Re-seeding `scrollRuns` before invoking the callback means
        // that re-entrant change just seeds a fresh baseline instead of firing again.
        var reentered = false
        tracker.onImmersionChange = { [weak self] immersed, extendsCard in
            self?.events.append((immersed, extendsCard))
            if !reentered {
                reentered = true
                self?.scrollView.contentOffset = CGPoint(x: 0, y: 40) // synthetic clamp
            }
        }
        drag(to: 0)
        drag(to: 15)
        drag(to: 30) // crosses fadeOutTravel, triggers the reentrant write above
        XCTAssertEqual(events.count, 1, "the reentrant offset write must not double-fire")

        // The reentrant write only seeded a new baseline — a further small move
        // from it should behave like a fresh start, not immediately refire.
        drag(to: 45) // run 5 from the 40 baseline — short of any threshold
        XCTAssertEqual(events.count, 1)
    }

    // MARK: - isActive gates everything

    func testInactiveTrackerIgnoresOffsetChangesEntirely() {
        tracker.isActive = false
        drag(to: 0)
        drag(to: 10)
        drag(to: 40)
        XCTAssertTrue(events.isEmpty)
    }

    func testGoingInactiveDropsAnInProgressRunSoReactivatingStartsFresh() {
        drag(to: 0)
        drag(to: 15) // a run in progress, short of the threshold
        tracker.isActive = false
        tracker.isActive = true
        drag(to: 30) // if the old run had survived, this would cross 24 and fire;
                     // instead it just re-seeds the baseline.
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Only a real drag/deceleration counts

    func testProgrammaticOffsetChangesWithoutDraggingOrDeceleratingAreIgnored() {
        scrollView.fakeIsDragging = false
        scrollView.fakeIsDecelerating = false
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        scrollView.contentOffset = CGPoint(x: 0, y: 40)
        XCTAssertTrue(events.isEmpty)
    }

    func testDeceleratingWithoutDraggingStillCounts() {
        scrollView.fakeIsDecelerating = true
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        scrollView.contentOffset = CGPoint(x: 0, y: 10)
        scrollView.contentOffset = CGPoint(x: 0, y: 30)
        XCTAssertEqual(events.count, 1)
    }

    // MARK: - observe(_:) is idempotent — no duplicate KVO registration

    func testObservingTheSameRootTwiceDoesNotDoubleFire() {
        tracker.observe(container)
        tracker.observe(container)
        drag(to: 0)
        drag(to: 15)
        drag(to: 30)
        XCTAssertEqual(events.count, 1, "a duplicate KVO registration would fire this twice")
    }
}
