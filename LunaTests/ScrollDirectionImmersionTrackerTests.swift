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

    /// Stands in for the reader card: records the immersion signal and answers
    /// the immersed card's extra height. `clampsOnFirstEvent` reproduces the
    /// synchronous card resize, whose offset clamp re-enters the KVO path from
    /// inside the callback.
    private final class ImmersionHost: ReaderImmersionTrackerDelegate {
        var events: [(immersed: Bool, extendsCard: Bool)] = []
        var bottomExtension: CGFloat = 0
        weak var clampsOnFirstEvent: UIScrollView?
        private var hasFired = false

        func immersionTracker(
            _ tracker: ScrollDirectionImmersionTracker,
            didChangeImmersion immersed: Bool, extendsCard: Bool
        ) {
            events.append((immersed, extendsCard))
            guard !hasFired, let scrollView = clampsOnFirstEvent else { return }
            hasFired = true
            scrollView.contentOffset = CGPoint(x: 0, y: 40)
        }

        func immersionBottomExtension(
            for tracker: ScrollDirectionImmersionTracker
        ) -> CGFloat { bottomExtension }
    }

    private var container: UIViewController!
    private var scrollView: FakeScrollView!
    private var tracker: ScrollDirectionImmersionTracker!
    private var host: ImmersionHost!
    private var events: [(immersed: Bool, extendsCard: Bool)] { host.events }

    override func setUp() {
        super.setUp()
        container = UIViewController()
        container.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        scrollView = FakeScrollView(frame: container.view.bounds)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentSize = CGSize(width: 400, height: 4000)
        container.view.addSubview(scrollView)

        tracker = ScrollDirectionImmersionTracker()
        host = ImmersionHost()
        tracker.delegate = host
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

    func testOffsetsDuringHostViewportTransitionDoNotStartAnotherImmersion() {
        tracker.suppressScrollDrivenImmersion(for: 60)
        drag(to: 40)
        drag(to: 90)
        drag(to: 150)
        XCTAssertTrue(events.isEmpty)
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

    func testArticleBottomRestoresOnlyOnceTheEndOfTheContentArrives() {
        host.bottomExtension = 100
        // Positioning/restoration itself is not user motion and must not count
        // toward the directional threshold. Maximum position is 3200.
        scrollView.fakeIsDragging = false
        scrollView.contentOffset = CGPoint(x: 0, y: 3000)
        drag(to: 3100) // 100pt still to go — a whole card extension early
        XCTAssertTrue(events.isEmpty, "the card extension is not the restore distance")
        drag(to: 3150) // 50pt short of the end
        XCTAssertTrue(events.isEmpty)
        drag(to: 3190) // 10pt remains: the end of the content has arrived
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.immersed, false)
    }

    func testDownwardDismissalIsIgnoredWithinHalfAViewportOfBottomRestore() {
        host.bottomExtension = 100
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
        host.bottomExtension = 100
        scrollView.fakeIsDragging = false
        scrollView.contentOffset = CGPoint(x: 0, y: 2600)
        drag(to: 2680) // seed with 520pt remaining
        drag(to: 2790) // 410pt remains, just outside the 400pt dead zone
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.immersed, true)
    }

    // MARK: - A short article keeps somewhere to dismiss from

    /// The dead zone is a fraction of the VIEWPORT measured from the end of the
    /// CONTENT, so on an article only a little longer than one screen it covered
    /// the whole scroll range — and then no downward gesture ANYWHERE in the
    /// article could dismiss the chrome. (What a truncated extraction looks like
    /// from the reader: every card's chrome stuck on, from the very top.)
    func testShortArticleStillDismissesChromeOnTheWayDown() {
        // Maximum position 400 — half the 800pt viewport, so the uncapped dead
        // zone would start at the article's very first point.
        scrollView.contentSize = CGSize(width: 400, height: 1_200)
        drag(to: 0)
        drag(to: 40)
        drag(to: 110) // cumulative run 110 >= fadeOutTravel
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.immersed, true)
    }

    /// Capped, not removed: a short article still owes its last stretch to the
    /// position-driven bottom restore.
    func testShortArticleStillKeepsAQuietTailForTheBottomRestore() {
        scrollView.contentSize = CGSize(width: 400, height: 1_200) // dead zone: last 100pt
        scrollView.fakeIsDragging = false
        scrollView.contentOffset = CGPoint(x: 0, y: 290)
        drag(to: 310) // 90pt remains — inside the capped dead zone
        drag(to: 360)
        XCTAssertTrue(events.isEmpty)
    }

    func testDeadZoneIsUnchangedOnAnArticleLongEnoughToAffordIt() {
        XCTAssertEqual(
            ScrollDirectionImmersionTracker.dismissalDeadZoneStart(
                viewportHeight: 800, scrollableRange: 3_200, bottomExtension: 100),
            400, accuracy: 0.001, "half a viewport, as before")
        XCTAssertEqual(
            ScrollDirectionImmersionTracker.dismissalDeadZoneStart(
                viewportHeight: 800, scrollableRange: 400, bottomExtension: 100),
            100, accuracy: 0.001, "a quarter of a short article, not half a viewport")
        XCTAssertEqual(
            ScrollDirectionImmersionTracker.dismissalDeadZoneStart(
                viewportHeight: 800, scrollableRange: 0, bottomExtension: 100),
            0, accuracy: 0.001, "an unscrollable article has no tail to protect")
    }

    // MARK: - The re-entrancy guard

    func testSyntheticOffsetChangeDuringTheCallbackDoesNotDoubleFire() {
        // The fade's card-bottom extension resizes the scroll view synchronously,
        // which can clamp the offset and re-enter this same KVO path from inside
        // the callback. Re-seeding `scrollRuns` before invoking the callback means
        // that re-entrant change just seeds a fresh baseline instead of firing again.
        host.clampsOnFirstEvent = scrollView
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

    func testTapOnlyModeIgnoresScrollDirectionAndPositionOverrides() {
        tracker.allowsScrollDrivenImmersion = false
        drag(to: 0)
        drag(to: 150)
        drag(to: 500)
        drag(to: 0)
        XCTAssertTrue(events.isEmpty)
    }

    func testTurningOnTapOnlyModeDropsAnInProgressDirectionalRun() {
        drag(to: 0)
        drag(to: 80)
        tracker.allowsScrollDrivenImmersion = false
        tracker.allowsScrollDrivenImmersion = true
        drag(to: 110)
        XCTAssertTrue(events.isEmpty, "the old 80pt run must not survive the policy change")
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

final class ReaderCardViewportPolicyTests: XCTestCase {

    func testEveryIPadUsesTapOnlyScrollChromeIncludingNarrowWindows() {
        XCTAssertTrue(ReaderCardViewportPolicy.usesTapOnlyScrollChrome(
            userInterfaceIdiom: .pad,
            viewportSize: CGSize(width: 500, height: 900)))
    }

    func testWiderThanTallPhoneUsesTapOnlyScrollChrome() {
        XCTAssertTrue(ReaderCardViewportPolicy.usesTapOnlyScrollChrome(
            userInterfaceIdiom: .phone,
            viewportSize: CGSize(width: 900, height: 500)))
    }

    func testPortraitPhoneKeepsDirectionalScrollChrome() {
        XCTAssertFalse(ReaderCardViewportPolicy.usesTapOnlyScrollChrome(
            userInterfaceIdiom: .phone,
            viewportSize: CGSize(width: 430, height: 932)))
    }
}
