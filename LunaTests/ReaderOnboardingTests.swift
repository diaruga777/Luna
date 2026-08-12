//
//  ReaderOnboardingTests.swift
//  LunaTests
//
//  The onboarding BEHAVIORAL core: the completion state machine (per-app
//  ownership, one-way central inheritance, the save leg's capability gate, the
//  reset), what a lesson is allowed to write, the completion → production-root
//  surface swap, and two hit-test guards.
//
//  Deliberately NOT here any more (see the test-trim notes): animation-timing
//  assertions (wave/demo-loop durations, the pulse's rate and curve, the
//  period's exit beat), copy checksums (per-app explainer prose, chunking,
//  feature lists, per-surface configuration string-for-string), artwork
//  geometry (launch composite frames, corona placement, cue silhouette paths)
//  and the Messages-replica suite. Those restate constants the code already
//  states, and between them they accounted for most of this file's 37 window
//  hosts and all five of its 15-second waits.
//

import LunaModels
import LunaDesignSystem
import LunaReaderUI
import LunaShareSurface
@testable import LunaStorage
import XCTest
@testable import Luna

final class ReaderOnboardingTests: XCTestCase {

    func testPriceSpotlightStartsBeyondEveryScreenEdge() {
        let scrim = OnboardingSpotlightScrimView(frame: CGRect(
            x: 0, y: 0, width: 393, height: 852))
        scrim.focusRect = CGRect(x: 240, y: 690, width: 137, height: 38)
        scrim.layoutIfNeeded()

        let center = CGPoint(
            x: scrim.focusRect.midX, y: scrim.focusRect.midY)
        let corners = [
            CGPoint(x: scrim.bounds.minX, y: scrim.bounds.minY),
            CGPoint(x: scrim.bounds.maxX, y: scrim.bounds.minY),
            CGPoint(x: scrim.bounds.minX, y: scrim.bounds.maxY),
            CGPoint(x: scrim.bounds.maxX, y: scrim.bounds.maxY),
        ]
        for corner in corners {
            XCTAssertGreaterThanOrEqual(
                scrim.openRadius,
                hypot(corner.x - center.x, corner.y - center.y),
                "the open cutout must contain every screen corner")
        }
    }

    // MARK: - Central sibling lesson selection

    func testCentralOnboardingChoosesTheHighestRankedMissingSibling() {
        XCTAssertEqual(
            OnboardingSurfaceConfiguration.highestRankedUninstalledSibling {
                $0 == .reader
            },
            .downloader)

        let configuration = OnboardingSurfaceConfiguration.configuration(
            for: .luna,
            saveSetupMode: .unavailable,
            demonstrationApp: .downloader)
        XCTAssertEqual(configuration.safariDemonstrationApps, [
            .downloader, .priceTracker, .reader,
        ])
        XCTAssertEqual(
            configuration.practiceURLString,
            ShareSetupPractice.instaTokURLString)
        XCTAssertTrue(
            OnboardingStrings.Instruction.safariPrompt(
                saveBenefit: configuration.saveBenefit,
                allApps: true).contains("All Luna apps"))
    }

    /// Central Luna's Safari lesson is all three siblings' lessons: each ending
    /// hands over to the next in rank order, the pass that completes the first
    /// full cycle raises the setup ask, and the cycle goes on turning underneath
    /// it rather than stopping on the lesson that raised it.
    @MainActor
    func testCentralSafariLessonCyclesItsThreeSiblingsAndKeepsGoingUnderTheAsk()
        throws
    {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let onboarding = AppOnboardingViewController(
            configuration: .configuration(
                for: .luna,
                saveSetupMode: .unavailable,
                demonstrationApp: .reader),
            onboardingStore: AppOnboardingStore(app: .luna, defaults: defaults),
            completion: AppOnboardingCompletion(
                makeCompletedRootViewController: { UIViewController() }))
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(true)
            window.isHidden = true
        }

        let safariButton = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
            })
        safariButton.sendActions(for: .touchUpInside)
        spinRunLoop(0.3)
        XCTAssertEqual(onboarding.safariDemonstrationAppForTesting, .reader)
        XCTAssertFalse(onboarding.hasSafariInstructionsForTesting)

        // Reader's lesson ends: the Downloader's takes the screen, still with
        // nothing over it — the first cycle is a demonstration, not an ask.
        onboarding.finishSafariLessonForTesting()
        spinRunLoop(OnboardingDemoLoopTiming.siblingLessonHoldDuration + 0.4)
        XCTAssertEqual(onboarding.safariDemonstrationAppForTesting, .downloader)
        XCTAssertFalse(onboarding.hasSafariInstructionsForTesting)

        onboarding.finishSafariLessonForTesting()
        spinRunLoop(OnboardingDemoLoopTiming.siblingLessonHoldDuration + 0.4)
        XCTAssertEqual(onboarding.safariDemonstrationAppForTesting, .priceTracker)
        XCTAssertFalse(onboarding.hasSafariInstructionsForTesting)

        // The third ending closes the first cycle: the ask comes up, and the
        // cycle wraps back to the first sibling underneath it.
        onboarding.finishSafariLessonForTesting()
        spinRunLoop(0.1)
        XCTAssertTrue(onboarding.hasSafariInstructionsForTesting)
        spinRunLoop(OnboardingDemoLoopTiming.siblingLessonHoldDuration + 0.4)
        XCTAssertEqual(onboarding.safariDemonstrationAppForTesting, .reader)
        XCTAssertTrue(onboarding.hasSafariInstructionsForTesting)
    }

    /// The first cycle is the pass the user is actually reading, so it plays at
    /// full length for all three siblings. The regression this guards: the
    /// brisker timeline was gated on the first LESSON, so the Downloader's and
    /// the Price Tracker's — never seen before — ran at 0.7x the first time
    /// they appeared. Only the wrap back to the first sibling, which is what
    /// closes the cycle, may speed the loop up.
    @MainActor
    func testTheFirstSafariCycleRunsAtFullPaceForEverySibling() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let onboarding = AppOnboardingViewController(
            configuration: .configuration(
                for: .luna,
                saveSetupMode: .unavailable,
                demonstrationApp: .reader),
            onboardingStore: AppOnboardingStore(app: .luna, defaults: defaults),
            completion: AppOnboardingCompletion(
                makeCompletedRootViewController: { UIViewController() }))
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(true)
            window.isHidden = true
        }

        let safariButton = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
            })
        safariButton.sendActions(for: .touchUpInside)
        spinRunLoop(0.3)

        for expected in [LunaApp.downloader, .priceTracker] {
            XCTAssertEqual(
                onboarding.safariLessonSpeedMultiplierForTesting, 1,
                accuracy: 0.001,
                "the lesson before \(expected) must not have sped the loop up")
            onboarding.finishSafariLessonForTesting()
            spinRunLoop(OnboardingDemoLoopTiming.siblingLessonHoldDuration + 0.4)
            XCTAssertEqual(onboarding.safariDemonstrationAppForTesting, expected)
        }

        // The third ending raises the ask; the cycle is still not closed until
        // the rotation wraps, so its freeze is a full-length one too.
        onboarding.finishSafariLessonForTesting()
        spinRunLoop(0.1)
        XCTAssertEqual(
            onboarding.safariLessonSpeedMultiplierForTesting, 1, accuracy: 0.001,
            "the freeze the ask comes up on belongs to the first cycle")

        spinRunLoop(OnboardingDemoLoopTiming.siblingLessonHoldDuration + 0.4)
        XCTAssertEqual(onboarding.safariDemonstrationAppForTesting, .reader)
        XCTAssertEqual(
            onboarding.safariLessonSpeedMultiplierForTesting,
            OnboardingDemoLoopTiming.repeatedSafariLessonSpeedMultiplier,
            accuracy: 0.001,
            "every sibling has now been seen once, so the loop speeds up")
    }

    /// A faceted app's ONE lesson is its whole cycle, so it too plays through
    /// at full length once before its replays shorten.
    @MainActor
    func testAFacetedAppsFirstSafariLessonRunsAtFullPace() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let onboarding = AppOnboardingViewController(
            configuration: .configuration(
                for: .downloader, saveSetupMode: .unavailable),
            onboardingStore: AppOnboardingStore(
                app: .downloader, defaults: defaults),
            completion: AppOnboardingCompletion(
                makeCompletedRootViewController: { UIViewController() }))
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(true)
            window.isHidden = true
        }

        let safariButton = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
            })
        safariButton.sendActions(for: .touchUpInside)
        spinRunLoop(0.3)
        XCTAssertEqual(
            onboarding.safariLessonSpeedMultiplierForTesting, 1, accuracy: 0.001)

        onboarding.finishSafariLessonForTesting()
        spinRunLoop(0.1)
        XCTAssertEqual(
            onboarding.safariLessonSpeedMultiplierForTesting, 1, accuracy: 0.001,
            "the ask's own freeze still belongs to the lesson just shown")

        spinRunLoop(OnboardingDemoLoopTiming.siblingLessonHoldDuration + 0.4)
        XCTAssertEqual(
            onboarding.safariLessonSpeedMultiplierForTesting,
            OnboardingDemoLoopTiming.repeatedSafariLessonSpeedMultiplier,
            accuracy: 0.001,
            "the replay that follows the one lesson is a second cycle")
    }

    /// The regression this guards: the shared popup's scrim used to be owned
    /// by whichever `SafariReplicaViewController` raised it, and central
    /// Luna's cycle reassigns `safariReplica` to a different sibling on every
    /// swap — an owner that stops being "current" on the very next swap.
    /// Reported symptom: after one or two cross-sibling swaps, the popup card
    /// stayed but its 65% scrim vanished, leaving the lesson full-bright
    /// underneath. Walks the cycle across TWO swaps under a live popup and
    /// checks, after each, that exactly one scrim is mounted at its full
    /// alpha alongside the still-live popup — polling the condition rather
    /// than trusting a fixed pump, since the swap's own completion still runs
    /// off a real animation-completion callback.
    @MainActor
    func testCentralSafariLessonKeepsExactlyOneScrimAcrossCrossSiblingSwaps()
        throws
    {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let onboarding = AppOnboardingViewController(
            configuration: .configuration(
                for: .luna,
                saveSetupMode: .unavailable,
                demonstrationApp: .reader),
            onboardingStore: AppOnboardingStore(app: .luna, defaults: defaults),
            completion: AppOnboardingCompletion(
                makeCompletedRootViewController: { UIViewController() }))
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(true)
            window.isHidden = true
        }

        func pollUntil(
            _ timeout: TimeInterval = 5, _ condition: () -> Bool
        ) {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline, !condition() {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }

        func assertExactlyOneLiveScrim(
            _ label: String, file: StaticString = #filePath, line: UInt = #line
        ) throws {
            let scrims = window.descendants(of: SafariSetupScrimView.self)
            XCTAssertEqual(
                scrims.count, 1,
                "\(label): expected exactly one scrim, found \(scrims.count)",
                file: file, line: line)
            let scrim = try XCTUnwrap(scrims.first, label, file: file, line: line)
            // The view itself is fully faded IN (opaque presentation, not
            // mid-fade or torn down) — the dimming lives in its background
            // color's own alpha component, checked separately below, not in
            // this `UIView.alpha`.
            XCTAssertEqual(
                scrim.alpha, 1, accuracy: 0.001,
                "\(label): the scrim view itself must be fully presented",
                file: file, line: line)
            XCTAssertEqual(
                scrim.backgroundColor?.cgColor.alpha ?? -1,
                OnboardingSafariSetupPopupView.scrimAlpha,
                accuracy: 0.001,
                "\(label): the scrim's dimming must stay at its constant alpha",
                file: file, line: line)
            XCTAssertNotNil(
                window.descendants(of: OnboardingSafariSetupPopupView.self).first,
                "\(label): the popup card must still be up too",
                file: file, line: line)
            XCTAssertTrue(
                onboarding.hasSafariInstructionsForTesting, label,
                file: file, line: line)
        }

        let safariButton = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
            })
        safariButton.sendActions(for: .touchUpInside)
        // The tap's own app-switcher hop has to clear (`appSwitcher == nil`)
        // before a lesson ending is accepted — matching the settle window the
        // sibling-cycling test above uses for the same tap.
        spinRunLoop(0.3)
        XCTAssertEqual(onboarding.safariDemonstrationAppForTesting, .reader)

        // Walk the first full cycle with nothing over it yet — a
        // demonstration, not an ask — then close it on the third ending.
        onboarding.finishSafariLessonForTesting()
        pollUntil { onboarding.safariDemonstrationAppForTesting == .downloader }
        onboarding.finishSafariLessonForTesting()
        pollUntil { onboarding.safariDemonstrationAppForTesting == .priceTracker }
        onboarding.finishSafariLessonForTesting()
        pollUntil { onboarding.hasSafariInstructionsForTesting }
        try assertExactlyOneLiveScrim("popup just raised, before any swap")

        // First cross-sibling swap under the live popup: priceTracker wraps
        // to reader. No new `finishSafariLessonForTesting()` call is needed —
        // the popup's own raise already scheduled this swap.
        pollUntil(OnboardingDemoLoopTiming.siblingLessonHoldDuration + 3) {
            onboarding.safariDemonstrationAppForTesting == .reader
        }
        XCTAssertEqual(onboarding.safariDemonstrationAppForTesting, .reader)
        try assertExactlyOneLiveScrim("one swap in")

        // Second cross-sibling swap: reader -> downloader. The reported bug
        // specifically needed "one or two swaps in," so this is the swap that
        // matters most.
        onboarding.finishSafariLessonForTesting()
        pollUntil(OnboardingDemoLoopTiming.siblingLessonHoldDuration + 3) {
            onboarding.safariDemonstrationAppForTesting == .downloader
        }
        XCTAssertEqual(onboarding.safariDemonstrationAppForTesting, .downloader)
        try assertExactlyOneLiveScrim("two swaps in")
    }

    /// A faceted app has ONE lesson. It ends on the shared setup popup exactly
    /// like central Luna's siblings do — every app's Safari lesson shares that
    /// one ending now — and since there is no sibling to hand off to, the same
    /// forever-loop that cycles central's three siblings underneath the popup
    /// just resets and replays this ONE lesson in place, pass after pass,
    /// with the popup staying up (raised once, not re-raised) throughout.
    @MainActor
    func testAFacetedAppsSafariLessonRaisesTheSharedPopupAndLoopsInPlace() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let onboarding = AppOnboardingViewController(
            configuration: .configuration(
                for: .downloader, saveSetupMode: .unavailable),
            onboardingStore: AppOnboardingStore(
                app: .downloader, defaults: defaults),
            completion: AppOnboardingCompletion(
                makeCompletedRootViewController: { UIViewController() }))
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(true)
            window.isHidden = true
        }

        let safariButton = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
            })
        safariButton.sendActions(for: .touchUpInside)
        spinRunLoop(0.3)
        onboarding.finishSafariLessonForTesting()
        spinRunLoop(0.1)

        XCTAssertEqual(onboarding.safariDemonstrationAppForTesting, .downloader)
        XCTAssertTrue(
            onboarding.hasSafariInstructionsForTesting,
            "the one lesson's own ending is where the shared popup comes up")

        // The freeze ends and the lesson resets and replays in place — the
        // popup itself is untouched by that, so it is still up rather than
        // needing to be raised a second time.
        spinRunLoop(OnboardingDemoLoopTiming.siblingLessonHoldDuration + 0.4)
        XCTAssertEqual(onboarding.safariDemonstrationAppForTesting, .downloader)
        XCTAssertTrue(onboarding.hasSafariInstructionsForTesting)
    }

    /// A pass that skips the extension-enable sheet still stands on the blocked
    /// post before the panel answers it: exercises exactly what
    /// `cycleSafariInstructionLesson`'s single-lesson fallback runs
    /// (`resetDemonstration()` then `beginDemonstration(showsExtensionSheet:
    /// false)`) directly on the video lesson, and confirms both that no second
    /// sheet is shown AND that the post is not wiped away in a frame — the
    /// sheet was the only thing holding it, so a pass without one used to open
    /// on its own answer. Independent of (and faster to run without) the outer
    /// freeze, which
    /// `testDownloaderSafariLessonLoopsThroughMultiplePassesUnderThePopup`
    /// below covers end to end.
    @MainActor
    func testVideoLessonReplayHoldsTheBlockedPostAndSkipsTheExtensionsSheet()
        throws
    {
        let safari = SafariReplicaViewController(
            configuration: .configuration(for: .downloader))
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = safari
        window.makeKeyAndVisible()
        safari.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let speed = OnboardingDemoLoopTiming.repeatedSafariLessonSpeedMultiplier
        let hold = OnboardingVideoDownloadTiming.pageHoldDuration * speed

        /// Runs the loop until the panel is up, or the deadline passes.
        func waitForPanel(
            _ overlay: OnboardingVideoDownloadOverlayView, timeout: TimeInterval
        ) {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline, overlay.backdropBlurWeightForTesting <= 0 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }

        safari.beginDemonstration(
            showsExtensionSheet: false, animationSpeedMultiplier: speed)
        let overlay = try XCTUnwrap(
            window.descendants(of: OnboardingVideoDownloadOverlayView.self).first)
        waitForPanel(overlay, timeout: hold + 4)
        XCTAssertGreaterThan(
            overlay.backdropBlurWeightForTesting, 0,
            "panel never reached the playing state on the first pass")

        // Simulate exactly what the loop's fallback does.
        safari.resetDemonstration()
        safari.beginDemonstration(
            showsExtensionSheet: false, animationSpeedMultiplier: speed)

        // The post is left alone for its own beat first — most of the hold has
        // to still be ahead of the panel, not a token pause in front of it.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: hold * 0.5))
        XCTAssertEqual(
            overlay.backdropBlurWeightForTesting, 0,
            "the blocked post must hold before the panel answers it")

        waitForPanel(overlay, timeout: hold + 4)
        XCTAssertGreaterThan(
            overlay.backdropBlurWeightForTesting, 0,
            "the replay never reached the player")
        XCTAssertTrue(
            window.descendants(of: OnboardingManageExtensionsSheetView.self).isEmpty,
            "a replay must not repeat the Manage Extensions sheet")
    }

    /// End to end, through `AppOnboardingViewController`'s own orchestration
    /// rather than the `finishSafariLessonForTesting()` shortcut: tap the
    /// intro's Safari button, let the real lesson play through to its own
    /// natural setup offer, confirm the 2.0s freeze holds it there, and then
    /// confirm the loop resets and replays the FULL beat sequence — not just
    /// once, but across a second pass too, since a single successful replay
    /// could still mask state that only breaks the next time around.
    @MainActor
    func testDownloaderSafariLessonLoopsThroughMultiplePassesUnderThePopup() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let onboarding = AppOnboardingViewController(
            configuration: .configuration(
                for: .downloader, saveSetupMode: .unavailable),
            onboardingStore: AppOnboardingStore(app: .downloader, defaults: defaults),
            completion: AppOnboardingCompletion(
                makeCompletedRootViewController: { UIViewController() }))
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let safariButton = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
            })
        safariButton.sendActions(for: .touchUpInside)

        // Let the REAL lesson play through to its own natural setup offer —
        // no shortcut. pageHold(3.2) + sheet pass(~1.5) + present(0.45) +
        // a short player hold is the nominal chain.
        let firstOfferDeadline = Date(timeIntervalSinceNow: 15)
        while Date() < firstOfferDeadline, !onboarding.hasSafariInstructionsForTesting {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        XCTAssertTrue(
            onboarding.hasSafariInstructionsForTesting,
            "the real lesson never naturally reached its setup offer")

        // After the first pass, the loop resets and replays directly at the
        // player; it never repeats the sheet or toggle demonstration.
        let replayDeadline = Date(timeIntervalSinceNow: 6)
        while Date() < replayDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        XCTAssertTrue(
            window.descendants(of: OnboardingManageExtensionsSheetView.self).isEmpty,
            "the loop must not re-show the sheet after its first pass")
        XCTAssertTrue(
            onboarding.hasSafariInstructionsForTesting,
            "the popup should still be up through the replay")

    }

    /// Safari's bar is what makes the facsimile read as a browser, and the
    /// lesson is about a browser: it used to slide away on the extension's
    /// toggle flip, so the reader watched the second half of the demonstration
    /// on a page with no chrome at all. It stays up now, through the wipe and
    /// past the lesson's own ending.
    @MainActor
    func testTheSafariBarStaysUpThroughTheWholeLesson() throws {
        let safari = SafariReplicaViewController(
            configuration: .configuration(for: .reader))
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = safari
        window.makeKeyAndVisible()
        safari.view.layoutIfNeeded()
        defer { window.isHidden = true }

        var didReachOffer = false
        safari.onDidReachSetupOffer = { didReachOffer = true }

        let bar = try XCTUnwrap(window.descendants(of: SafariBottomBar.self).first)
        XCTAssertEqual(bar.alpha, 1, accuracy: 0.001)

        safari.beginDemonstration(showsExtensionSheet: false)
        let deadline = Date(timeIntervalSinceNow: 12)
        while Date() < deadline, !didReachOffer {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(didReachOffer, "the explainer never finished its wipe")

        XCTAssertEqual(
            bar.alpha, 1, accuracy: 0.001,
            "the bar must still be up once the page is clean")
        XCTAssertEqual(
            bar.layer.presentation()?.transform.m42 ?? 0, 0, accuracy: 0.001,
            "the bar must not have slid off its own height")
        XCTAssertNotNil(
            safari.highlightedLinkRegion,
            "the address field is still there to save from")
    }

    /// The one end-of-lesson signal the host cycles on: the Downloader's panel
    /// reports it once it has arrived and the clip is playing — the panel no
    /// longer grows a chin of enable steps to mark that moment, since that ask
    /// now lives on the shared setup popup instead.
    @MainActor
    func testTheVideoLessonReportsReachingItsSetupOffer() {
        let overlay = OnboardingVideoDownloadOverlayView(
            configuration: .configuration(
                for: .downloader, saveSetupMode: .unavailable))
        overlay.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        overlay.layoutIfNeeded()
        var reported = 0
        overlay.onDidReachSetupOffer = { reported += 1 }

        overlay.enterPlayerStateForTesting()
        overlay.reportSetupOffer()
        // A second call is the same run's already-made offer, not a new one.
        overlay.reportSetupOffer()

        XCTAssertEqual(reported, 1)
    }

    private func spinRunLoop(_ duration: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
    }

    // MARK: - Completion state machine

    func testCompletionIsOwnedByInjectedPerAppDefaults() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let setup = LunaSetupStatusStore(defaults: defaults)
        let reader = AppOnboardingStore(
            app: .reader, defaults: defaults, setupStatusStore: setup)
        let downloader = AppOnboardingStore(
            app: .downloader, defaults: defaults, setupStatusStore: setup)
        XCTAssertFalse(reader.isCompleted)
        XCTAssertFalse(downloader.isCompleted)
        reader.markCompleted()
        XCTAssertTrue(reader.isCompleted)
        XCTAssertFalse(downloader.isCompleted)
        reader.resetCompletion()

        reader.markSaveSetupHandled()
        XCTAssertTrue(reader.hasHandledSaveSetup)
        XCTAssertFalse(downloader.hasHandledSaveSetup)
        XCTAssertFalse(reader.isCompleted)
        reader.markSafariSetupHandled()
        XCTAssertTrue(reader.hasHandledSafariSetup)
        XCTAssertTrue(reader.isCompleted)
        reader.resetCompletion()
        XCTAssertFalse(reader.isCompleted)
        XCTAssertFalse(reader.hasHandledSaveSetup)
        XCTAssertFalse(reader.hasHandledSafariSetup)
    }

    func testCentralSetupEvidenceSkipsOnlyANewFacetedAppsOnboarding() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let setup = LunaSetupStatusStore(defaults: defaults)
        let facet = AppOnboardingStore(
            app: .reader,
            defaults: defaults,
            setupStatusStore: setup,
            saveSetupMode: .actionButtonShortcut)
        setup.recordShortcutRun(for: .luna)
        XCTAssertFalse(facet.isCompleted)

        defaults.set(true, forKey: LunaSetupStatusStore.centralSafariKey)
        XCTAssertTrue(facet.isCompleted)
    }

    /// Inheritance is one-way: a fully configured facet leaves central Luna's
    /// own first run untouched.
    func testAFacetsSetupEvidenceNeverCompletesCentralLuna() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let setup = LunaSetupStatusStore(defaults: defaults)
        let central = AppOnboardingStore(
            app: .luna,
            defaults: defaults,
            setupStatusStore: setup,
            saveSetupMode: .actionButtonShortcut)
        setup.recordShortcutInstallPressed(for: .reader)
        setup.recordShortcutRun(for: .reader)
        defaults.set(true, forKey: LunaSetupStatusStore.sharedSafariKey)

        XCTAssertFalse(central.hasFinishedSafariSetup)
        XCTAssertFalse(central.hasFinishedSaveSetup)
        XCTAssertFalse(central.isCompleted)
    }

    /// There is no fallback lesson: a device that cannot run the Action Button
    /// shortcut has no save setup at all, and its util card omits the button.
    func testTheSaveLessonExistsOnlyWhereTheActionButtonShortcutCanRun() {
        func mode(
            os: Int,
            model: String,
            simulator: Bool = false
        ) -> OnboardingSaveSetupMode {
            OnboardingDeviceCapabilities(
                operatingSystemMajorVersion: os,
                modelIdentifier: model,
                isSimulator: simulator).saveSetupMode
        }

        XCTAssertEqual(mode(os: 26, model: "iPhone17,1"), .unavailable)
        XCTAssertEqual(mode(os: 27, model: "iPhone15,4"), .unavailable)
        XCTAssertEqual(mode(os: 27, model: "iPad16,3"), .unavailable)
        XCTAssertEqual(
            mode(os: 27, model: "iPhone17,1", simulator: true),
            .actionButtonShortcut)
        XCTAssertEqual(mode(os: 27, model: "iPhone16,1"), .actionButtonShortcut)
        XCTAssertEqual(mode(os: 27, model: "iPhone16,2"), .actionButtonShortcut)
        XCTAssertEqual(mode(os: 27, model: "iPhone17,1"), .actionButtonShortcut)
    }

    /// A device with no save lesson owes nothing on that leg, so Safari alone
    /// finishes its first run.
    func testWithNoSaveLessonTheSafariLegAloneCompletesOnboarding() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AppOnboardingStore(
            app: .reader,
            defaults: defaults,
            setupStatusStore: LunaSetupStatusStore(defaults: defaults),
            saveSetupMode: .unavailable)
        XCTAssertTrue(store.hasFinishedSaveSetup)
        XCTAssertFalse(store.isCompleted)

        store.markSafariSetupHandled()

        XCTAssertTrue(store.isCompleted)
    }

    func testOnboardingResetClearsCompletionAndEveryRunEvidence() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let onboarding = AppOnboardingStore(app: .reader, defaults: defaults)
        onboarding.markCompleted()
        XCTAssertTrue(onboarding.isCompleted)
        onboarding.resetCompletion()
        XCTAssertFalse(onboarding.isCompleted)

        let status = LunaSetupStatusStore(defaults: defaults)
        defaults.set(true, forKey: LunaSetupStatusStore.sharedSafariKey)
        defaults.set(true, forKey: LunaSetupStatusStore.centralSafariKey)
        status.recordShortcutInstallPressed(for: .reader)
        status.recordShortcutInstallPressed(for: .luna)
        status.recordShortcutRun(for: .reader)
        status.recordShortcutRun(for: .luna)
        status.recordShareActionRun(isCentral: false)
        status.recordShareActionRun(isCentral: true)
        XCTAssertTrue(status.safariHasRun(isCentral: false))
        XCTAssertTrue(status.safariHasRun(isCentral: true))
        XCTAssertTrue(status.shortcutHasRun(for: .reader))
        XCTAssertTrue(status.shortcutHasRun(for: .luna))
        XCTAssertTrue(status.shareActionHasRun(isCentral: false))
        XCTAssertTrue(status.shareActionHasRun(isCentral: true))

        status.resetAllRunEvidence()
        XCTAssertFalse(status.safariHasRun(isCentral: false))
        XCTAssertFalse(status.safariHasRun(isCentral: true))
        XCTAssertFalse(status.shortcutInstallWasPressed(for: .reader))
        XCTAssertFalse(status.shortcutInstallWasPressed(for: .luna))
        XCTAssertFalse(status.shortcutHasRun(for: .reader))
        XCTAssertFalse(status.shortcutHasRun(for: .luna))
        XCTAssertFalse(status.shareActionHasRun(isCentral: false))
        XCTAssertFalse(status.shareActionHasRun(isCentral: true))
    }

    // MARK: - What a lesson may write

    /// An install updating from a build that DID store the demonstration item
    /// loses it at the next launch — and only it.
    func testLaunchSweepRemovesOnlyTheLegacyDemonstrationSave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderOnboardingTests-\(UUID().uuidString)")
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defaults.removePersistentDomain(forName: suite)
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }

        let contentStore = ReadingListStore(containerURL: directory)
        let registry = AppOnboardingStore(app: .luna, defaults: defaults)
        let userSave = contentStore.add(urlString: "https://example.com/real")
        let legacy = contentStore.add(urlString: BundledLunaArticle.urlString)
        registry.recordLegacyTemporarySaveForTesting(identifier: legacy.id)

        BundledLunaArticle.cleanupLegacyTemporarySave(
            registry: registry, in: contentStore)

        XCTAssertNil(contentStore.item(withID: legacy.id))
        XCTAssertEqual(contentStore.item(withID: userSave.id)?.id, userSave.id)
        XCTAssertNil(registry.temporarySaveIdentifier)

        // A second launch has nothing to claim: an unmarked store is untouched.
        BundledLunaArticle.cleanupLegacyTemporarySave(
            registry: registry, in: contentStore)
        XCTAssertEqual(contentStore.items().count, 1)
    }

    func testSharePracticeRecognizesEveryMockLinkWithoutSavingVariants() throws {
        for value in ShareSetupPractice.urlStrings {
            XCTAssertTrue(ShareSetupPractice.matches(try XCTUnwrap(URL(string: value))))
            XCTAssertTrue(ShareSetupPractice.matches(try XCTUnwrap(URL(string: value + "/#demo"))))
        }
        XCTAssertFalse(ShareSetupPractice.matches(
            try XCTUnwrap(URL(string: "https://example.com/about"))))
    }

    /// The save demonstration is no longer a picture — it runs the REAL share
    /// surface over a real link — so "entering a lesson writes nothing" is now an
    /// invariant with teeth rather than a tautology. Entering leaves the deck
    /// exactly as empty as the user left it, and claims no temporary save.
    @MainActor
    func testEnteringALessonWritesNothingToTheStore() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let registry = AppOnboardingStore(app: .reader, defaults: defaults)
        let productionRoot = UINavigationController(
            rootViewController: UIViewController())
        let onboarding = AppOnboardingViewController(
            configuration: .configuration(for: .reader),
            onboardingStore: registry,
            completion: AppOnboardingCompletion(
                makeCompletedRootViewController: { productionRoot }))
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()

        let before = Set(ReadingListStore.shared.items().map(\.id))
        let button = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
            })
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(true)
            window.isHidden = true
        }
        button.sendActions(for: .touchUpInside)
        // The preload — where the demonstration item used to be installed —
        // runs one stage per run-loop turn.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(Set(ReadingListStore.shared.items().map(\.id)), before)
        XCTAssertNil(registry.temporarySaveIdentifier)
    }

    // MARK: - Completion swaps in the production surface

    /// A save from ANY surface answers the first run: the deck's content watch
    /// sees a newer stored identifier while the intro is on screen, latches
    /// completion, and swaps the window's root over to the real app.
    @MainActor
    func testExternalSaveWhileIntroIsVisibleCompletesOnboarding() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let registry = AppOnboardingStore(app: .reader, defaults: defaults)
        let changed = Notification.Name("onboarding.externalSave.\(UUID())")
        var identifiers: Set<UUID> = [UUID()]
        let productionRoot = UIViewController()
        productionRoot.view.backgroundColor = .black
        let onboarding = AppOnboardingViewController(
            configuration: .configuration(for: .reader),
            onboardingStore: registry,
            completion: AppOnboardingCompletion(
                contentWatch: OnboardingContentWatch(
                    changeNotifications: [changed],
                    storedIdentifiers: { identifiers }),
                makeCompletedRootViewController: { productionRoot }))
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        defer { window.isHidden = true }

        identifiers.insert(UUID())
        NotificationCenter.default.post(name: changed, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(registry.isCompleted)
        XCTAssertTrue(window.rootViewController === productionRoot)
    }

    // MARK: - Layout / hit-test guards

    func testSettingsOpenerReportsExhaustedFallbacks() {
        var opened: Bool?
        SystemSettingsLink.openFirstAvailable([]) { opened = $0 }
        XCTAssertEqual(opened, false)
    }

    /// The conversation's link is whatever the lesson resolved — and when that is
    /// a live Save of the Week it is a real editorial URL, publisher and dated
    /// path and slug. The whole of it is the thing the user is being pointed at,
    /// so the bubble wraps it rather than truncating a spaceless string on its
    /// first line. Three lines is where it finally gives up.
    @MainActor
    func testMessageURLBubbleWrapsALongLinkRatherThanTruncatingIt() throws {
        let urlString = "https://www.example-publisher.com/technology/archive/"
            + "2026/08/the-long-slow-decline-of-the-open-web/684213/"
        let bubble = OnboardingMessageURLBubble(showsTail: true)
        bubble.setURL(urlString)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 300))
        container.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: 16),
            bubble.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutIfNeeded()

        let label = try XCTUnwrap(container.descendants(of: UILabel.self).first)
        XCTAssertEqual(
            label.text?.replacingOccurrences(of: "\u{200B}", with: ""),
            urlString,
            "Only invisible break opportunities are added to the link")
        let lineHeight = UIFont
            .systemFont(ofSize: OnboardingMessageBubble.textSize - 1).lineHeight
        XCTAssertGreaterThan(
            label.bounds.height, lineHeight * 1.5,
            "A link this long has to wrap: got \(label.bounds.height)pt")
        XCTAssertLessThanOrEqual(
            label.bounds.height, lineHeight * 3.5,
            "…and stops at three lines: got \(label.bounds.height)pt")
        XCTAssertLessThanOrEqual(
            bubble.bounds.width, OnboardingMessageBubble.maxWidth,
            "The bubble keeps iMessage's width cap")
    }

    @MainActor
    func testMessagesReplicaUsesTheFullConversationPaneOnWideLayouts() throws {
        let replica = MessagesReplicaViewController(
            urlString: "https://www.example-publisher.com/technology/archive/"
                + "2026/08/the-long-slow-decline-of-the-open-web/684213/")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = replica
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        replica.view.layoutIfNeeded()
        replica.revealStagedConversationImmediately()
        replica.view.layoutIfNeeded()

        let greeting = try XCTUnwrap(replica.view.descendants(of: UIView.self)
            .first {
                $0.accessibilityIdentifier ==
                    OnboardingStrings.Accessibility.messagesGreeting.value()
            })
        let answer = try XCTUnwrap(replica.view.descendants(of: UIView.self)
            .first {
                $0.accessibilityIdentifier ==
                    OnboardingStrings.Accessibility.messagesAnswer.value()
            })
        let link = try XCTUnwrap(replica.view.descendants(of: UIView.self)
            .first {
                $0.accessibilityIdentifier ==
                    OnboardingStrings.Accessibility.messagesLatestIncoming.value()
            })

        let greetingFrame = replica.view.convert(greeting.bounds, from: greeting)
        let answerFrame = replica.view.convert(answer.bounds, from: answer)
        XCTAssertLessThanOrEqual(greetingFrame.minX, 28)
        XCTAssertGreaterThanOrEqual(answerFrame.maxX, 996)
        XCTAssertGreaterThan(
            link.bounds.width, OnboardingMessageBubble.maxWidth,
            "Wide panes should let a long iMessage bubble use the available detail view")
    }

    /// The Safari lesson end to end, in the REAL hierarchy — the one place the
    /// overlays can shadow each other. Pressing the intro's Safari action
    /// expands the replica full-bleed over the app's production root (mounted
    /// as a CHILD, not swapped in for it); the staged sequence (buried page,
    /// Manage Extensions sheet, wipe) ends with the shared setup popup's own
    /// Set-up/Skip buttons hittable — they live on the WINDOW now, not inside
    /// `OnboardingSafariPageView`, so a Reader-faceted app has exactly this one
    /// popup rather than the page's own former actions; and skipping returns
    /// to an intro whose Safari button is still ENABLED — a skipped lesson
    /// keeps its button, only a completed one is retired.
    ///
    /// The deadlines below are failure caps, not waits: every loop breaks the
    /// moment its condition holds.
    @MainActor
    func testSafariLessonMountsOverProductionRootAndLeavesItsActionsHittable() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let productionRoot = UINavigationController(
            rootViewController: UIViewController())
        let onboarding = AppOnboardingViewController(
            configuration: .configuration(for: .reader),
            onboardingStore: AppOnboardingStore(app: .reader, defaults: defaults),
            completion: AppOnboardingCompletion(
                makeCompletedRootViewController: { productionRoot }))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let button = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
            })
        button.sendActions(for: .touchUpInside)

        let mountDeadline = Date(timeIntervalSinceNow: 8)
        while Date() < mountDeadline,
              onboarding.children.compactMap({
                  $0 as? SafariReplicaViewController
              }).isEmpty {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        let safari = try XCTUnwrap(
            onboarding.children.compactMap {
                $0 as? SafariReplicaViewController
            }.first)
        XCTAssertEqual(safari.view.frame, onboarding.view.bounds)
        XCTAssertTrue(
            onboarding.savedRootViewControllerForTesting === productionRoot,
            "The save destination must be the app's production root controller")
        XCTAssertTrue(
            productionRoot.parent === onboarding,
            "The production root must be mounted behind Safari during the save")

        // Ride the real staged sequence — the buried page, the Manage
        // Extensions sheet with its toggle, then the wipe — until the shared
        // setup popup's own buttons come up hittable. The popup is
        // window-hosted (a sibling of `onboarding.view`, not a descendant of
        // it), so the search has to be over the WINDOW.
        func hitView(for label: String) -> (button: UIButton, hit: UIView?)? {
            guard let action = window
                .descendants(of: UIButton.self).first(where: {
                    $0.accessibilityLabel == label
                })
            else { return nil }
            let point = window.convert(
                CGPoint(x: action.bounds.midX, y: action.bounds.midY),
                from: action)
            return (action, window.hitTest(point, with: nil))
        }
        func isHittable(_ label: String) -> Bool {
            guard let probe = hitView(for: label) else { return false }
            return probe.hit === probe.button
                || probe.hit?.isDescendant(of: probe.button) == true
        }
        let deadline = Date(timeIntervalSinceNow: 10)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if isHittable(OnboardingStrings.Safari.setUpInSafari.value()),
               isHittable(OnboardingStrings.Safari.skip.value()) { break }
        }

        for label in [
            OnboardingStrings.Safari.setUpInSafari.value(),
            OnboardingStrings.Safari.skip.value(),
        ] {
            let probe = try XCTUnwrap(hitView(for: label))
            let popup = window
                .descendants(of: OnboardingSafariSetupPopupView.self).first
            let buttonFrame = window.convert(
                probe.button.bounds, from: probe.button)
            let popupFrame = popup.map {
                window.convert($0.bounds, from: $0)
            }
            XCTAssertTrue(
                probe.hit === probe.button
                    || probe.hit?.isDescendant(of: probe.button) == true,
                """
                \(label) is shadowed by \(String(describing: probe.hit)); \
                button in window: \(buttonFrame), \
                popup in window: \(String(describing: popupFrame)), \
                button superview chain: \(sequence(
                    first: probe.button as UIView, next: \.superview)
                    .map { "\(type(of: $0)) \($0.frame) hidden=\($0.isHidden) alpha=\($0.alpha)" }
                    .joined(separator: " <- "))
                """)
        }

        // Skipping finishes only the Safari lesson and app-switches back to
        // the three-action intro card — still enabled, marked skipped rather
        // than completed, since the shortcut lesson isn't done yet.
        let skip = try XCTUnwrap(
            window.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Safari.skip.value()
            })
        skip.sendActions(for: .touchUpInside)
        let introDeadline = Date(timeIntervalSinceNow: 8)
        var safariIntroButton: UIButton?
        while Date() < introDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            safariIntroButton = onboarding.view.descendants(of: UIButton.self)
                .first {
                    $0.accessibilityLabel
                        == OnboardingStrings.Intro.safariAction.value()
                }
            if onboarding.view.descendants(of: UIPasteControl.self)
                .first?.isHidden == false
            {
                break
            }
        }
        XCTAssertTrue(try XCTUnwrap(safariIntroButton).isEnabled)
        XCTAssertNil(safariIntroButton?.accessibilityValue)
    }

    /// The price tracker's Safari lesson is a different demonstration with the
    /// same ending. It runs on the mock product page instead of the explainer:
    /// the seller pill answers there, the lesson's own 70% spotlight scrim
    /// closes on it, and the shared setup popup — window-hosted, not a card
    /// inside the lesson's own view any more — comes up above BOTH that
    /// spotlight and its own 65% scrim, stacked and both still visible. Its
    /// buttons have to be hittable through that stack, or the lesson ends on
    /// an ask nobody can reach; and the re-entry contract (a hop to Safari
    /// with nothing to show for it) has to put the buttons live again.
    ///
    /// The deadline is a failure cap, not a wait: the loop breaks the moment
    /// the popup is up.
    @MainActor
    func testPriceLessonEndsOnAHittableSetupPopupOverTheAnsweredPill() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Through the real host, not a bare replica: the popup is
        // `AppOnboardingViewController`'s own state now, not the replica's.
        let onboarding = AppOnboardingViewController(
            configuration: .configuration(
                for: .priceTracker, saveSetupMode: .unavailable),
            onboardingStore: AppOnboardingStore(app: .priceTracker, defaults: defaults),
            completion: AppOnboardingCompletion(
                makeCompletedRootViewController: { UIViewController() }))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let safariButton = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
            })
        safariButton.sendActions(for: .touchUpInside)

        // Let the REAL lesson run to its own natural setup offer — no
        // shortcut — so the overlay's states below reflect what actually
        // happened, not a forced signal.
        let offerDeadline = Date(timeIntervalSinceNow: 15)
        while Date() < offerDeadline, !onboarding.hasSafariInstructionsForTesting {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        XCTAssertTrue(
            onboarding.hasSafariInstructionsForTesting,
            "the real lesson never naturally reached its setup offer")
        let overlay = try XCTUnwrap(
            window.descendants(of: OnboardingPriceComparisonOverlayView.self)
                .first,
            "The price tracker's Safari lesson must mount its own overlay")

        // The popup's own buttons: it is window-hosted, a SIBLING of the
        // whole onboarding hierarchy rather than a descendant of the price
        // overlay.
        func hitView(for label: String) -> (button: UIButton, hit: UIView?)? {
            guard let action = window.descendants(of: UIButton.self).first(where: {
                $0.accessibilityLabel == label
            })
            else { return nil }
            let point = window.convert(
                CGPoint(x: action.bounds.midX, y: action.bounds.midY),
                from: action)
            return (action, window.hitTest(point, with: nil))
        }
        func isHittable(_ label: String) -> Bool {
            guard let probe = hitView(for: label) else { return false }
            return probe.hit === probe.button
                || probe.hit?.isDescendant(of: probe.button) == true
        }

        let labels = [
            OnboardingStrings.Safari.setUpInSafari.value(),
            OnboardingStrings.Safari.skip.value(),
        ]
        let deadline = Date(timeIntervalSinceNow: 12)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if labels.allSatisfy(isHittable) { break }
        }

        for label in labels {
            let probe = try XCTUnwrap(hitView(for: label))
            XCTAssertTrue(
                probe.hit === probe.button
                    || probe.hit?.isDescendant(of: probe.button) == true,
                """
                \(label) is shadowed by \(String(describing: probe.hit)); \
                button in window: \(window.convert(probe.button.bounds, from: probe.button))
                """)
        }
        XCTAssertFalse(
            overlay.sellerPillForTesting.isLooking,
            "The pill must have left its waiting state for the price it found")
        XCTAssertTrue(
            overlay.spotlightForTesting.isCollapsedForTesting,
            "The lesson's own spotlight must have closed on the pill")
        XCTAssertGreaterThan(
            overlay.spotlightForTesting.alpha, 0,
            "the spotlight stays up — the popup's scrim stacks on top of it "
                + "rather than replacing it")

        // The popup sits above the WHOLE onboarding hierarchy — replica,
        // spotlight and all — since it is added directly to the window rather
        // than into `onboarding.view`'s own subtree.
        let popup = try XCTUnwrap(
            window.descendants(of: OnboardingSafariSetupPopupView.self).first)
        let windowSubviews = window.subviews
        XCTAssertGreaterThan(
            windowSubviews.firstIndex(of: popup) ?? -1,
            windowSubviews.firstIndex(of: onboarding.view) ?? -1,
            "The setup popup must sit above the whole onboarding hierarchy")

        // The return leg from real Safari with nothing to show for it: the
        // popup's buttons come back live rather than staying disabled from
        // whichever tap sent the user there.
        popup.setActionsEnabled(false)
        onboarding.restoreSharedSafariSetupPopupForTesting()
        XCTAssertTrue(popup.activateButtonForTesting.isUserInteractionEnabled)
        XCTAssertTrue(popup.skipButtonForTesting.isUserInteractionEnabled)
    }

    /// Every recovery route stays reachable when the external open fails, and
    /// the overlay that says so is modal to assistive technology (hiding its
    /// siblings while it's up, restoring them when it goes).
    @MainActor
    func testExternalOpenFailureKeepsEverySetupRecoveryAvailable() throws {
        let safari = SafariReplicaViewController(
            configuration: .configuration(for: .reader))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize))
        window.rootViewController = safari
        window.makeKeyAndVisible()
        safari.view.layoutIfNeeded()
        safari.showExternalOpenFailure(destination: .shortcuts)
        defer { window.isHidden = true }

        let mountedLabels = window.descendants(of: UIButton.self)
            .compactMap(\.accessibilityLabel)
        let overlay = window.descendants(of: DemoInstructionOverlay.self).first
        let mountedOverlay = try XCTUnwrap(overlay)
        let obscuredSiblings = window.subviews.filter { $0 !== mountedOverlay }
        XCTAssertTrue(Set(mountedLabels).isSuperset(
            of: Set([
                OnboardingStrings.Instruction.setUpSafari.value(),
                OnboardingStrings.Instruction.installShortcut.value(),
                OnboardingStrings.Instruction.setActionButton.value(),
            ])))
        XCTAssertTrue(mountedOverlay.accessibilityViewIsModal)
        XCTAssertTrue(obscuredSiblings.allSatisfy(\.accessibilityElementsHidden))

        mountedOverlay.removeFromSuperview()
        XCTAssertTrue(obscuredSiblings.allSatisfy {
            !$0.accessibilityElementsHidden
        })
    }

    // MARK: - The headline is a diff between two states

    // Ported wholesale from main's `feat(onboarding): every app's headline is
    // a diff between two states`. This file was cut from 52 tests to 15 on this
    // branch, but that trim removed coverage that RESTATED code; these are the
    // shipped feature's own proofs — the shared-run algorithm, its no-run
    // fallback, and the per-app invariant — plus the layout consequences that
    // only exist because the headline now animates around an anchor.

    func testIntroStagesTheSameRevealAcrossEveryFragment() throws {
        let intro = OnboardingIntroCardContentViewController(
            introCopy: OnboardingIntroCopy(
                initialText: "You want to read.",
                finalText: "You want to read more."))
        intro.loadViewIfNeeded()
        intro.view.frame = CGRect(x: 0, y: 0, width: 354, height: 629)
        intro.view.layoutIfNeeded()

        // Both sides of the difference plus the run they share, every one of
        // them waiting behind the same front.
        let lines = intro.view.descendants(of: MoonRevealLineView.self)
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            XCTAssertFalse(line.isFullyRevealed)
            XCTAssertFalse(line.occluderHasVisibleChrome)
            XCTAssertTrue(line.usesGlyphEdgeIllumination)
        }

        let buttons = intro.view.descendants(of: UIButton.self)
        XCTAssertEqual(intro.view.backgroundColor, .black)
        XCTAssertFalse(intro.view.subviews.contains {
            $0.accessibilityIdentifier
                == OnboardingStrings.Accessibility.introIconCluster.value()
        })
        XCTAssertTrue(buttons.contains {
            $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
                && $0.configuration?.image != nil
        })
        XCTAssertTrue(buttons.contains {
            $0.accessibilityLabel
                == OnboardingStrings.Intro.shortcutAction.value()
                && $0.configuration?.image != nil
        })
        let pasteControl = try XCTUnwrap(
            intro.view.descendants(of: UIPasteControl.self).first)
        // The system draws it: nothing of ours is painted over the control.
        XCTAssertEqual(pasteControl.layer.opacity, 1)
        XCTAssertTrue(intro.view.descendants(of: UITextField.self).contains {
            $0.placeholder == OnboardingStrings.Intro.paste.value()
                && !$0.isUserInteractionEnabled
        })
        let button = try XCTUnwrap(buttons.first {
            $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
        })
        let tintAlpha = try XCTUnwrap(
            button.configuration?.baseBackgroundColor?.cgColor.alpha)
        XCTAssertEqual(tintAlpha, 0.24, accuracy: 0.001)

        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = intro
        window.makeKeyAndVisible()
        intro.view.frame = window.bounds
        intro.view.layoutIfNeeded()
        for action in intro.view.descendants(of: UIControl.self) {
            action.alpha = 1
        }
        intro.setActionsEnabled(true)
        defer { window.isHidden = true }
        let point = window.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY),
            from: button)
        let hit = window.hitTest(point, with: nil)
        XCTAssertTrue(
            hit === button || hit?.isDescendant(of: button) == true,
            "Safari intro action is shadowed by \(String(describing: hit))")
    }

    func testHeadlineTransitionKeepsTheLongestRunTheTwoStatesShare() {
        // Growth on the right: the whole first state is the anchor.
        let reader = OnboardingHeadlineTransition(from: "Read.", to: "Read more.")
        XCTAssertEqual(reader.shared, "Read")
        XCTAssertEqual(reader.initialPrefix, "")
        XCTAssertEqual(reader.initialSuffix, ".")
        XCTAssertEqual(reader.finalPrefix, "")
        XCTAssertEqual(reader.finalSuffix, " more.")

        // Growth on the LEFT, with a letter changing case at the seam: the
        // capital leaves with the words in front of it.
        let price = OnboardingHeadlineTransition(
            from: "Miss a sale", to: "Never miss a sale")
        XCTAssertEqual(price.shared, "iss a sale")
        XCTAssertEqual(price.initialPrefix, "M")
        XCTAssertEqual(price.initialSuffix, "")
        XCTAssertEqual(price.finalPrefix, "Never m")
        XCTAssertEqual(price.finalSuffix, "")

        // Both sides at once, and the anchor carries its trailing space.
        let bothSides = OnboardingHeadlineTransition(
            from: "Sign up to watch.", to: "No sign up needed.")
        XCTAssertEqual(bothSides.shared, "ign up ")
        XCTAssertEqual(bothSides.initialPrefix, "S")
        XCTAssertEqual(bothSides.initialSuffix, "to watch.")
        XCTAssertEqual(bothSides.finalPrefix, "No s")
        XCTAssertEqual(bothSides.finalSuffix, "needed.")

        // The anchor is a run, not a word: it may start mid-word on both sides.
        let luna = OnboardingHeadlineTransition(
            from: "All your Luna apps.", to: "One Luna app.")
        XCTAssertEqual(luna.shared, " Luna app")
        XCTAssertEqual(luna.initialPrefix, "All your")
        XCTAssertEqual(luna.initialSuffix, "s.")
        XCTAssertEqual(luna.finalPrefix, "One")
        XCTAssertEqual(luna.finalSuffix, ".")

        for transition in [reader, price, bothSides, luna] {
            XCTAssertFalse(transition.isFullReplacement)
            XCTAssertEqual(
                transition.initialText,
                transition.initialPrefix + transition.shared
                    + transition.initialSuffix)
            XCTAssertEqual(
                transition.finalText,
                transition.finalPrefix + transition.shared + transition.finalSuffix)
        }
    }

    func testHeadlineTransitionReplacesItselfWhenNoRunIsWorthStandingStillFor() {
        for (initial, final) in [
            ("Read.", "Watch."),          // nothing in common at all
            ("Miss a sale", "Never!"),    // one letter, and a coincidence
            ("Hi!", "Ho!"),               // two characters, neither a word
        ] {
            let transition = OnboardingHeadlineTransition(from: initial, to: final)
            XCTAssertTrue(
                transition.isFullReplacement,
                "\(initial) → \(final) should replace itself outright")
            XCTAssertEqual(transition.initialPrefix, initial)
            XCTAssertEqual(transition.finalPrefix, final)
            XCTAssertEqual(transition.initialSuffix, "")
            XCTAssertEqual(transition.finalSuffix, "")
            XCTAssertEqual(transition.departingFragments, [initial])
            XCTAssertEqual(transition.arrivingFragments, [final])
        }
    }

    func testEveryAppsHeadlineHoldsSomethingStillAcrossItsTwoBeats() {
        for app in LunaApp.allCases {
            let copy = OnboardingStrings.introCopy(for: app)
            var hasSomethingToSay = false
            for line in copy.lines {
                let transition = OnboardingHeadlineTransition(
                    from: line.initialText, to: line.finalText)
                if line.initialText.isEmpty {
                    // A line the first beat never says has nothing to hold
                    // still — it arrives whole under its own front.
                    XCTAssertTrue(
                        transition.isFullReplacement,
                        "\(app)'s added line is an arrival, not a diff")
                } else {
                    XCTAssertFalse(
                        transition.isFullReplacement,
                        "\(app)'s headline animates a difference, not a replacement")
                }
                hasSomethingToSay = hasSomethingToSay
                    || !transition.arrivingFragments.isEmpty
                    || !transition.departingFragments.isEmpty
            }
            XCTAssertTrue(
                hasSomethingToSay,
                "\(app)'s second beat has to have something to say")
        }
    }

    func testIntroCentresTheFinishedSentenceAndNeverMovesWhatBothStatesShare() throws {
        let intro = OnboardingIntroCardContentViewController(
            introCopy: OnboardingStrings.introCopy(for: .reader))
        intro.loadViewIfNeeded()
        intro.view.frame = CGRect(x: 0, y: 0, width: 354, height: 629)
        intro.view.layoutIfNeeded()

        let headline = try XCTUnwrap(
            intro.view.subviews.compactMap {
                $0 as? OnboardingIntroHeadlineView
            }.first)
        let fragments = headline.fragments
        let shared = try XCTUnwrap(fragments.shared)
        let departing = try XCTUnwrap(fragments.initialSuffix)
        let arriving = try XCTUnwrap(fragments.finalSuffix)
        XCTAssertNil(fragments.initialPrefix, "Reader's copy grows on the right")
        XCTAssertNil(fragments.finalPrefix)

        XCTAssertEqual(
            headline.frame.minY,
            AppOnboardingLayout.contentTop(in: intro.view.bounds),
            accuracy: 0.01,
            "One line keeps the vertical position the first of two lines had")
        XCTAssertEqual(headline.frame.height, 44, accuracy: 0.01)

        // One typesetting per sentence, and here they start at the same place:
        // the anchor is at the head of both.
        XCTAssertEqual(departing.frame.minX, shared.frame.minX, accuracy: 0.01)
        XCTAssertEqual(arriving.frame.minX, shared.frame.minX, accuracy: 0.01)

        let font = try XCTUnwrap(headline.font)
        XCTAssertEqual(font.pointSize, 25, "This card has room for the full size")
        XCTAssertEqual(
            shared.frame.minX + width(headline.finalText, font: font) / 2,
            headline.bounds.midX,
            accuracy: 1,
            "The finished sentence is what is centred")
        XCTAssertLessThan(
            shared.frame.minX + width(headline.initialText, font: font) / 2,
            headline.bounds.midX - 20,
            "The first beat therefore lands left of centre, which is the point")

        for fragment in fragments.all {
            XCTAssertFalse(fragment.isFullyRevealed)
            XCTAssertTrue(fragment.usesGlyphEdgeIllumination)
            XCTAssertFalse(fragment.occluderHasVisibleChrome)
        }

        let firstBeat = expectation(description: "the initial sentence arrives")
        headline.revealFirstBeat(duration: 0.02) { firstBeat.fulfill() }
        wait(for: [firstBeat], timeout: 5)
        XCTAssertTrue(shared.isFullyRevealed)
        XCTAssertTrue(departing.isFullyRevealed)
        XCTAssertFalse(arriving.isFullyRevealed)
        XCTAssertEqual(headline.accessibilityLabel, headline.initialText)

        let anchorFrame = shared.frame
        let secondBeat = expectation(description: "the difference plays")
        headline.revealSecondBeat(duration: 0.02) { secondBeat.fulfill() }
        wait(for: [secondBeat], timeout: 5)
        XCTAssertTrue(arriving.isFullyRevealed)
        XCTAssertTrue(departing.isFullyConcealed)
        XCTAssertFalse(departing.isFullyRevealed)
        XCTAssertTrue(
            shared.isFullyRevealed, "The second beat does not touch the anchor")
        XCTAssertEqual(shared.frame, anchorFrame)
        XCTAssertEqual(headline.accessibilityLabel, headline.finalText)
        XCTAssertTrue(headline.isAccessibilityElement)
        XCTAssertFalse(shared.isAccessibilityElement)
    }

    func testIntroShiftsTheInitialSentenceRightWhenTheCopyGrowsOnTheLeft() throws {
        // Copy that grows on the LEFT, written here rather than taken from an
        // app: what is under test is the geometry rule, and which app happens
        // to ship a left-growing headline this week is not part of it.
        let headline = OnboardingIntroHeadlineView(
            copy: OnboardingIntroCopy(
                initialText: "Miss a sale", finalText: "Never miss a sale"))
        headline.frame = CGRect(x: 0, y: 0, width: 306, height: 44)
        headline.setNeedsLayout()
        headline.layoutIfNeeded()

        let font = try XCTUnwrap(headline.font)
        let departing = try XCTUnwrap(headline.fragments.initialPrefix)
        let arriving = try XCTUnwrap(headline.fragments.finalPrefix)
        let shared = try XCTUnwrap(headline.fragments.shared)
        XCTAssertNil(headline.fragments.initialSuffix, "Nothing changes at the end")
        XCTAssertNil(headline.fragments.finalSuffix)

        // “Miss a sale” has to sit RIGHT of centre for “iss a sale” to land
        // where the finished “Never miss a sale” puts it.
        XCTAssertGreaterThan(departing.frame.minX, shared.frame.minX + 20)
        XCTAssertEqual(
            departing.frame.minX + width(headline.transition.initialPrefix, font: font),
            shared.frame.minX + width(headline.transition.finalPrefix, font: font),
            accuracy: 0.01,
            "The anchor occupies one position, whichever state is on screen")
        XCTAssertEqual(arriving.frame.minX, shared.frame.minX, accuracy: 0.01)
        XCTAssertEqual(
            shared.frame.minX + width(headline.finalText, font: font) / 2,
            headline.bounds.midX,
            accuracy: 1,
            "The finished sentence is still the centred one")
    }

    func testIntroAnimatesBothSidesOfTheAnchorInOneBeat() throws {
        // The central app's copy, which is the shipped headline with fragments
        // on both sides of its anchor in both states.
        let headline = OnboardingIntroHeadlineView(
            copy: OnboardingStrings.introCopy(for: .luna))
        headline.frame = CGRect(x: 0, y: 0, width: 306, height: 44)
        headline.setNeedsLayout()
        headline.layoutIfNeeded()

        let shared = try XCTUnwrap(headline.fragments.shared)
        let departingPrefix = try XCTUnwrap(headline.fragments.initialPrefix)
        let departingSuffix = try XCTUnwrap(headline.fragments.initialSuffix)
        let arrivingPrefix = try XCTUnwrap(headline.fragments.finalPrefix)
        let arrivingSuffix = try XCTUnwrap(headline.fragments.finalSuffix)

        let firstBeat = expectation(description: "the claim arrives")
        headline.revealFirstBeat(duration: 0.02) { firstBeat.fulfill() }
        wait(for: [firstBeat], timeout: 5)
        XCTAssertTrue(shared.isFullyRevealed)
        XCTAssertTrue(departingPrefix.isFullyRevealed)
        XCTAssertTrue(departingSuffix.isFullyRevealed)
        XCTAssertFalse(arrivingPrefix.isFullyRevealed)
        XCTAssertFalse(arrivingSuffix.isFullyRevealed)

        let secondBeat = expectation(description: "the correction plays")
        headline.revealSecondBeat(duration: 0.02) { secondBeat.fulfill() }
        wait(for: [secondBeat], timeout: 5)
        XCTAssertTrue(arrivingPrefix.isFullyRevealed)
        XCTAssertTrue(arrivingSuffix.isFullyRevealed)
        XCTAssertTrue(departingPrefix.isFullyConcealed)
        XCTAssertTrue(departingSuffix.isFullyConcealed)
        XCTAssertTrue(shared.isFullyRevealed)
        XCTAssertEqual(headline.accessibilityLabel, headline.finalText)
    }

    func testIntroStartsADepartureWithTheArrivalsItStandsBeside() {
        let headline = OnboardingIntroHeadlineView(
            copy: OnboardingStrings.introCopy(for: .reader))
        headline.frame = CGRect(x: 0, y: 0, width: 306, height: 44)
        headline.setNeedsLayout()
        headline.layoutIfNeeded()

        // A period's ink sits about an x-height below “more”'s, and one front
        // descending through the shared frame would reach it that much later —
        // uncovering the top of the “m” while the period still stood beside it.
        // The period's own front starts that far ahead so both tops go at once.
        let xHeight = (headline.font ?? .systemFont(ofSize: 25)).xHeight
        let lead = headline.frontLead(forDeparting: ".")
        XCTAssertGreaterThan(
            lead, xHeight * 0.4,
            "Without a real lead the period outlives the tail's first glyph")
        XCTAssertLessThan(
            lead, xHeight,
            "The lead is a drop between two inks, not a whole glyph height")
        // Type as tall as what arrives beside it needs no lead at all.
        XCTAssertEqual(headline.frontLead(forDeparting: "Read"), 0, accuracy: 0.01)
    }

    func testIntroShrinksItsCopyToFitANarrowCardWithoutLosingTheAnchor() throws {
        let copy = OnboardingStrings.introCopy(for: .luna)
        let roomy = OnboardingIntroHeadlineView(copy: copy)
        roomy.frame = CGRect(x: 0, y: 0, width: 306, height: 44)
        roomy.setNeedsLayout()
        roomy.layoutIfNeeded()
        let narrow = OnboardingIntroHeadlineView(copy: copy)
        narrow.frame = CGRect(x: 0, y: 0, width: 190, height: 44)
        narrow.setNeedsLayout()
        narrow.layoutIfNeeded()

        let roomyFont = try XCTUnwrap(roomy.font)
        let narrowFont = try XCTUnwrap(narrow.font)
        XCTAssertEqual(roomyFont.pointSize, 25)
        XCTAssertLessThan(
            narrowFont.pointSize, roomyFont.pointSize,
            "A card this narrow cannot hold the copy at full size")

        // Both states still fit, and the anchor is still one position.
        let shared = try XCTUnwrap(narrow.fragments.shared)
        let departing = try XCTUnwrap(narrow.fragments.initialSuffix)
        XCTAssertEqual(
            departing.frame.minX
                + width(narrow.transition.initialPrefix, font: narrowFont),
            shared.frame.minX
                + width(narrow.transition.finalPrefix, font: narrowFont),
            accuracy: 0.01)
        for text in [narrow.initialText, narrow.finalText] {
            XCTAssertLessThanOrEqual(
                width(text, font: narrowFont), narrow.bounds.width + 0.5,
                "\(text) still overflows the card")
        }

        // Every app's shipped copy, on compact through wide onboarding cards.
        // The 190-point fixture above is deliberately narrower than any
        // supported screen; these are the real ones, and a multi-line headline
        // has to hold every one of its lines inside them.
        for cardWidth: CGFloat in [272, 306, 382] {
            for app in LunaApp.allCases {
                let headline = OnboardingIntroHeadlineView(
                    copy: OnboardingStrings.introCopy(for: app))
                headline.frame = CGRect(
                    x: 0, y: 0, width: cardWidth, height: headline.height)
                headline.setNeedsLayout()
                headline.layoutIfNeeded()
                for fragment in headline.allFragments {
                    XCTAssertGreaterThanOrEqual(
                        fragment.frame.minX, -0.5,
                        "\(app) on a \(cardWidth)-point card pushes copy past "
                            + "its leading edge")
                    XCTAssertLessThanOrEqual(
                        fragment.frame.maxX, cardWidth + 0.5,
                        "\(app) on a \(cardWidth)-point card pushes copy past "
                            + "its trailing edge")
                }
            }
        }
    }

    // MARK: - A headline whose second beat adds a line

    /// The Downloader's headline is two lines, and the second beat is only the
    /// second of them: the first line says the same thing in both states, so it
    /// neither re-animates nor moves, and the line beneath it — absent from the
    /// initial copy entirely — arrives under its own front into room that was
    /// reserved for it from the start.
    func testASecondHeadlineLineArrivesWithoutDisturbingTheFirst() throws {
        let copy = OnboardingStrings.introCopy(for: .downloader)
        XCTAssertEqual(copy.initialText, "Download any video.")
        XCTAssertEqual(copy.finalText, "Download any video.\nNo sign in required.")

        let headline = OnboardingIntroHeadlineView(copy: copy)
        XCTAssertEqual(headline.lines.count, 2)
        XCTAssertEqual(
            headline.height, OnboardingIntroHeadlineView.lineHeight * 2,
            "The second line's room is reserved before it has anything on it")
        headline.frame = CGRect(x: 0, y: 0, width: 306, height: headline.height)
        headline.setNeedsLayout()
        headline.layoutIfNeeded()

        // The first line is the whole sentence, anchored: nothing of it leaves
        // and nothing joins it.
        let first = headline.lines[0]
        let firstLine = try XCTUnwrap(first.fragments.shared)
        XCTAssertTrue(first.fragments.departing.isEmpty)
        XCTAssertTrue(first.fragments.arriving.isEmpty)

        // The second is pure arrival, one line lower.
        let second = headline.lines[1]
        let secondLine = try XCTUnwrap(second.fragments.finalPrefix)
        XCTAssertTrue(second.transition.isFullReplacement)
        XCTAssertEqual(second.fragments.initialSentence.count, 0)
        XCTAssertEqual(
            secondLine.frame.minY,
            firstLine.frame.minY + OnboardingIntroHeadlineView.lineHeight,
            accuracy: 0.01)

        let firstBeat = expectation(description: "the first line arrives")
        headline.revealFirstBeat(duration: 0.02) { firstBeat.fulfill() }
        wait(for: [firstBeat], timeout: 5)
        XCTAssertTrue(firstLine.isFullyRevealed)
        XCTAssertFalse(secondLine.isFullyRevealed)
        XCTAssertEqual(headline.accessibilityLabel, "Download any video.")

        let firstFrame = firstLine.frame
        let secondBeat = expectation(description: "the second line arrives")
        headline.revealSecondBeat(duration: 0.02) { secondBeat.fulfill() }
        wait(for: [secondBeat], timeout: 5)
        XCTAssertTrue(secondLine.isFullyRevealed)
        XCTAssertTrue(
            firstLine.isFullyRevealed, "The first line is not touched again")
        XCTAssertFalse(firstLine.isFullyConcealed)
        XCTAssertEqual(firstLine.frame, firstFrame, "…and it does not reflow")
        XCTAssertEqual(headline.accessibilityLabel, headline.finalText)
        XCTAssertTrue(headline.isAccessibilityElement)
    }

    /// Paged back to, a two-line headline stands finished — both lines, with no
    /// sweep left to play.
    func testASecondHeadlineLineStandsFinishedWhenTheSweepIsNotThisAppearances() throws {
        let headline = OnboardingIntroHeadlineView(
            copy: OnboardingStrings.introCopy(for: .downloader))
        headline.showFinishedState()
        headline.frame = CGRect(x: 0, y: 0, width: 306, height: headline.height)
        headline.setNeedsLayout()
        headline.layoutIfNeeded()

        for fragment in headline.allFragments {
            XCTAssertTrue(
                fragment.isFullyRevealed,
                "Both lines of the finished sentence are already on screen")
        }
        XCTAssertEqual(headline.accessibilityLabel, headline.finalText)
    }

    /// The text width the headline transition measures against, with the same
    /// attributes the label renders with — kerning and ligatures off, so a
    /// shared run measures identically in both states.
    private func width(_ string: String, font: UIFont) -> CGFloat {
        NSAttributedString(
            string: string,
            attributes: [.font: font, .kern: 0, .ligature: 0]
        ).size().width
    }
}

private extension UIView {
    func descendants<View: UIView>(of type: View.Type) -> [View] {
        subviews.flatMap { view -> [View] in
            let matching = (view as? View).map { [$0] } ?? []
            return matching + view.descendants(of: type)
        }
    }

}
