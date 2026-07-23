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
        drag(to: 80) // cumulative run 80 < fadeOutTravel (100)
        XCTAssertTrue(events.isEmpty)
    }

    func testDownwardTravelPastThresholdFiresImmersedTrue() {
        drag(to: 0)
        drag(to: 40)
        drag(to: 80)
        drag(to: 110) // cumulative run 110 >= 100
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.immersed, true)
        XCTAssertEqual(events.first?.extendsCard, true, "the scroll reader extends the card on immersion")
    }

    func testTravelAccumulatesAcrossMultipleSmallDeltasNotJustTheLastOne() {
        drag(to: 0)
        drag(to: 30)  // run 30
        drag(to: 70)  // run 70
        XCTAssertTrue(events.isEmpty, "70pt of accumulated travel hasn't crossed 100pt yet")
        drag(to: 105) // run 105 >= 100
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.immersed, true)
    }

    // MARK: - A direction flip resets the run (jitter doesn't cross the threshold)

    func testADirectionFlipResetsTheAccumulatedRun() {
        drag(to: 0)
        drag(to: 60)  // run 60, downward
        drag(to: 50)  // flips upward: run resets to -10
        drag(to: 125) // flips back downward: run resets to 75, still short of 100
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Fade-in threshold (scrolling up), shorter than fade-out

    func testUpwardTravelPastThresholdFiresImmersedFalse() {
        drag(to: 600)
        drag(to: 570)  // run -30, below the 50pt fade-in threshold
        XCTAssertTrue(events.isEmpty)
        drag(to: 549)  // run -51, beyond the threshold
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.immersed, false)
        XCTAssertEqual(events.first?.extendsCard, true)
    }

    func testTinyUpwardCorrectionDoesNotRestoreChrome() {
        drag(to: 600)
        drag(to: 584)
        drag(to: 568)
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

    func testDownwardDismissalIsIgnoredWithinHalfAViewportOfBottomRestore() {
        tracker.bottomRevealDistance = { 100 }
        // With an 800pt viewport, the directional dismissal dead zone begins
        // 400pt from the maximum position (half a viewport).
        scrollView.fakeIsDragging = false
        scrollView.contentOffset = CGPoint(x: 0, y: 2600)
        drag(to: 2790) // 410pt remaining: seed just outside the dead zone
        drag(to: 2810) // enters at 390pt remaining; accumulated down-run is discarded
        drag(to: 2850) // further downward travel in the dead zone stays ignored
        XCTAssertTrue(events.isEmpty)
    }

    func testDownwardDismissalStillAppliesJustOutsideBottomDeadZone() {
        tracker.bottomRevealDistance = { 100 }
        scrollView.fakeIsDragging = false
        scrollView.contentOffset = CGPoint(x: 0, y: 2600)
        drag(to: 2680) // seed with 520pt remaining
        drag(to: 2790) // 410pt remains, just outside the 400pt dead zone
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.immersed, true)
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
        drag(to: 60)
        drag(to: 110) // crosses fadeOutTravel, triggers the reentrant write above
        XCTAssertEqual(events.count, 1, "the reentrant offset write must not double-fire")

        // The reentrant write only seeded a new baseline — a further small move
        // from it should behave like a fresh start, not immediately refire.
        drag(to: 80) // run 40 from the reentrant baseline — short of any threshold
        XCTAssertEqual(events.count, 1)
    }

    // MARK: - isActive gates everything

    func testInactiveTrackerIgnoresOffsetChangesEntirely() {
        tracker.isActive = false
        drag(to: 0)
        drag(to: 60)
        drag(to: 110)
        XCTAssertTrue(events.isEmpty)
    }

    func testGoingInactiveDropsAnInProgressRunSoReactivatingStartsFresh() {
        drag(to: 0)
        drag(to: 60) // a run in progress, short of the threshold
        tracker.isActive = false
        tracker.isActive = true
        drag(to: 110) // if the old run had survived, this would cross 100 and fire;
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
        scrollView.contentOffset = CGPoint(x: 0, y: 50)
        scrollView.contentOffset = CGPoint(x: 0, y: 110)
        XCTAssertEqual(events.count, 1)
    }

    // MARK: - observe(_:) is idempotent — no duplicate KVO registration

    func testObservingTheSameRootTwiceDoesNotDoubleFire() {
        tracker.observe(container)
        tracker.observe(container)
        drag(to: 0)
        drag(to: 60)
        drag(to: 110)
        XCTAssertEqual(events.count, 1, "a duplicate KVO registration would fire this twice")
    }
}
