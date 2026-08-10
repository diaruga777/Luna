//
//  UtilCardTests.swift
//  LunaTests
//

import CryptoKit
import LunaDesignSystem
import LunaModels
import LunaStorage
import LunaWeekly
import UIKit
import XCTest
@testable import Luna

@MainActor
final class UtilCardTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var container: URL!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    /// ONE store instance for the whole test: the card holds a reference to it,
    /// so seeding through a second instance would never reach the card.
    private var weekly: WeeklySaveStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "UtilCardTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("UtilCardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        weekly = WeeklySaveStore(containerURL: container, now: { self.clock })
        UIView.setAnimationsEnabled(false)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        weekly = nil
        try? FileManager.default.removeItem(at: container)
        container = nil
        UIView.setAnimationsEnabled(true)
        try super.tearDownWithError()
    }

    func testOnboardingVariantAlwaysContainsPasteAndBothSetupButtons() {
        let card = makeCard(showsOnboarding: true)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()

        XCTAssertNotNil(card.view.descendant(
            identifier: OnboardingStrings.Accessibility.introPaste.value()))
        let labels = Set(card.view.descendants(of: UIButton.self).compactMap(\.accessibilityLabel))
        XCTAssertTrue(labels.contains(OnboardingStrings.Intro.safariAction.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Intro.shortcutAction.value()))
        XCTAssertTrue(card.view.descendants(of: OnboardingIntroHeadlineView.self).count == 1)
    }

    func testCompletingSetupKeepsLaunchVariantUntilANewCardIsConstructed() {
        let store = makeStore()
        let currentSession = makeCard(showsOnboarding: true, store: store)
        currentSession.loadViewIfNeeded()

        store.markSafariSetupHandled()
        store.markSaveSetupHandled()

        XCTAssertTrue(store.isCompleted)
        XCTAssertEqual(currentSession.view.descendants(of: UIButton.self).count, 2)

        // What the next launch does before any root reads the state.
        store.retireCompletedSetupButtons()
        let nextLaunch = makeCard(showsOnboarding: false, store: store)
        nextLaunch.loadViewIfNeeded()
        XCTAssertTrue(nextLaunch.view.descendants(of: UIButton.self).isEmpty)
        XCTAssertTrue(nextLaunch.view.descendants(of: OnboardingIntroHeadlineView.self).isEmpty)
        XCTAssertNotNil(nextLaunch.view.descendant(
            identifier: OnboardingStrings.Accessibility.introPaste.value()))
    }

    // MARK: - The weekly row is conditional

    func testAnEmptyWeeklyStoreShowsNoRowAndASeededOneShowsIt() {
        let withoutRow = makeCard(showsOnboarding: true)
        withoutRow.loadViewIfNeeded()
        withoutRow.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        withoutRow.view.layoutIfNeeded()
        XCTAssertNil(withoutRow.view.descendant(identifier: "utilCard.saveOfTheWeek"))

        seedWeekly(.article, url: "https://example.com/a", title: "A Read")
        let withRow = makeCard(showsOnboarding: true)
        withRow.loadViewIfNeeded()
        withRow.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        withRow.view.layoutIfNeeded()
        XCTAssertNotNil(withRow.view.descendant(identifier: "utilCard.saveOfTheWeek"))
    }

    // MARK: - The “or” seam

    func testOrSeparatorShowsWhileSetupIsOpenAndTheDeckHoldsNothing() throws {
        let card = makeCard(showsOnboarding: true, hasSaves: false)
        card.loadViewIfNeeded()

        let separator = try XCTUnwrap(orSeparator(in: card))
        XCTAssertFalse(separator.isHidden)
    }

    func testOrSeparatorStandsDownOnceTheDeckHoldsASave() throws {
        let card = makeCard(showsOnboarding: true, hasSaves: true)
        card.loadViewIfNeeded()

        let separator = try XCTUnwrap(orSeparator(in: card))
        XCTAssertTrue(separator.isHidden)
    }

    func testOrSeparatorLeavesWhenBothSetupLegsAreHandled() throws {
        let store = makeStore()
        let card = makeCard(showsOnboarding: true, hasSaves: false, store: store)
        card.loadViewIfNeeded()
        let separator = try XCTUnwrap(orSeparator(in: card))
        XCTAssertFalse(separator.isHidden)

        store.markSafariSetupHandled()
        store.markSaveSetupHandled()

        XCTAssertTrue(separator.isHidden)
    }

    func testCompletedVariantHasNoOrSeparator() {
        let card = makeCard(showsOnboarding: false, hasSaves: false)
        card.loadViewIfNeeded()

        XCTAssertNil(orSeparator(in: card))
    }

    // MARK: - The headline belongs to the launch

    func testIntroHeadlineIsAlreadyFinishedWhenItIsNotTheLaunchsOwn() throws {
        let card = makeCard(showsOnboarding: true, animatesIntro: false)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()

        let headline = try XCTUnwrap(
            card.view.descendants(of: OnboardingIntroHeadlineView.self).first)
        let fragments = headline.fragments
        // The finished sentence stands: what both states share, plus whatever
        // only the second one says. The first state's own words are gone.
        for line in [fragments.shared] + fragments.arriving.map(Optional.some) {
            XCTAssertTrue(try XCTUnwrap(line).isFullyRevealed)
        }
        XCTAssertFalse(fragments.departing.isEmpty)
        for line in fragments.departing { XCTAssertTrue(line.isFullyConcealed) }
    }

    func testIntroHeadlineWaitsBehindItsFrontOnTheLaunchItBelongsTo() throws {
        let card = makeCard(showsOnboarding: true, animatesIntro: true)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()

        let headline = try XCTUnwrap(
            card.view.descendants(of: OnboardingIntroHeadlineView.self).first)
        let fragments = headline.fragments
        XCTAssertFalse(fragments.all.isEmpty)
        for line in fragments.all { XCTAssertFalse(line.isFullyRevealed) }
    }

    // MARK: - The headline speaks first

    /// On the launch that animates the sweep, everything below the headline
    /// waits invisible for the group reveal that follows the bloom.
    func testTheLaunchsOwnIntroHoldsEveryOtherElementBehindTheHeadline() throws {
        let card = makeCard(showsOnboarding: true, animatesIntro: true)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()

        let paste = try XCTUnwrap(card.view.descendant(
            identifier: OnboardingStrings.Accessibility.introPaste.value()))
        XCTAssertEqual(paste.alpha, 0)
        for button in card.view.descendants(of: UIButton.self)
        where button.superview === card.view {
            XCTAssertEqual(button.alpha, 0)
        }
        let headline = try XCTUnwrap(
            card.view.descendants(of: OnboardingIntroHeadlineView.self).first)
        XCTAssertEqual(headline.alpha, 1, "The headline is what everyone waits on")
    }

    /// Any appearance that does not animate the sweep owes nobody a wait.
    func testANonAnimatingAppearanceShowsItsElementsImmediately() throws {
        let card = makeCard(showsOnboarding: true, animatesIntro: false)
        card.loadViewIfNeeded()

        let paste = try XCTUnwrap(card.view.descendant(
            identifier: OnboardingStrings.Accessibility.introPaste.value()))
        XCTAssertEqual(paste.alpha, 1)
        for button in card.view.descendants(of: UIButton.self)
        where button.superview === card.view {
            XCTAssertEqual(button.alpha, 1)
        }
    }

    /// A weekly value landing while the headline is still speaking stays out of
    /// sight until the headline has made room for the delayed weekly reveal.
    func testAWeeklyValueArrivingMidSweepWaitsForTheDelayedWeeklyReveal() throws {
        let card = makeCard(showsOnboarding: true, animatesIntro: true)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()
        let host = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.weeklyHost"))
        XCTAssertTrue(host.isHidden)

        seedWeekly(.article, url: "https://example.com/a", title: "A Read")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(host.isHidden, "The weekly row waits for the headline exit")
    }

    // MARK: - Layout

    func testSetupActionsStackUpFromThePasteFieldAndTheHeadlineSitsBelowTheCardTop() throws {
        seedWeekly(.article, url: "https://example.com/a", title: "A Read")
        let card = makeCard(showsOnboarding: true, hasSaves: false)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        card.view.layoutIfNeeded()

        let paste = try XCTUnwrap(card.view.descendant(
            identifier: OnboardingStrings.Accessibility.introPaste.value()))
        let separator = try XCTUnwrap(orSeparator(in: card))
        let buttons = card.view.descendants(of: UIButton.self)
            .filter { $0.superview === card.view }
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(buttons.count, 2)
        let headline = try XCTUnwrap(
            card.view.descendants(of: OnboardingIntroHeadlineView.self).first)
        let weekly = try XCTUnwrap(card.view.descendant(identifier: "utilCard.saveOfTheWeek"))
        // The row lives inside the host's clipping child, so its own frame is
        // in that child's space — compare it in card coordinates.
        let weeklyFrame = weekly.convert(weekly.bounds, to: card.view)

        // Bottom-up: paste field, the seam, both setup actions.
        XCTAssertLessThan(separator.frame.maxY, paste.frame.minY)
        XCTAssertLessThan(buttons[1].frame.maxY, separator.frame.minY)
        XCTAssertLessThan(buttons[0].frame.maxY, buttons[1].frame.minY)
        // The headline is neither on the card's shoulder nor as low as the third
        // the standalone onboarding root used.
        XCTAssertGreaterThan(headline.frame.minY, card.view.bounds.height * 0.2)
        XCTAssertLessThan(headline.frame.minY, card.view.bounds.height / 3)
        XCTAssertGreaterThan(weeklyFrame.minY, headline.frame.maxY)
        XCTAssertLessThan(weeklyFrame.maxY, buttons[0].frame.minY)
    }

    /// There is no share-sheet lesson to fall back to, so a device that cannot
    /// run the Action Button shortcut is offered nothing in that slot — and
    /// Safari takes the bottom one rather than leaving a hole.
    func testWithNoSaveLessonSafariIsTheOnlyActionAndItTakesTheBottomSlot() throws {
        let both = makeCard(showsOnboarding: true, hasSaves: false)
        both.loadViewIfNeeded()
        both.view.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        both.view.layoutIfNeeded()
        let bottomSlot = try XCTUnwrap(
            actionButtons(in: both).map(\.frame.minY).max())

        let card = makeCard(
            showsOnboarding: true, hasSaves: false, saveSetupMode: .unavailable)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        card.view.layoutIfNeeded()

        let buttons = actionButtons(in: card)
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(
            buttons[0].accessibilityLabel,
            OnboardingStrings.Intro.safariAction.value())
        XCTAssertEqual(buttons[0].frame.minY, bottomSlot)
    }

    // MARK: - The email nudge

    func testEmailIsEarnedByThreeSavesOrTwoDaysWithTheFirst() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func earned(_ dates: [Date]) -> Bool {
            UtilCardSetupOffer.emailIsEarned(saveDates: dates, now: now)
        }

        XCTAssertFalse(earned([]))
        XCTAssertFalse(earned([now, now.addingTimeInterval(-60)]))
        XCTAssertTrue(earned([now, now, now]))
        // The clock runs from the FIRST save, whatever order they arrive in.
        XCTAssertFalse(earned([now.addingTimeInterval(-47 * 3600), now]))
        XCTAssertTrue(earned([now, now.addingTimeInterval(-48 * 3600)]))
    }

    func testEmailWaitsWhileBothSystemLessonsStillWantTheirSlots() {
        let card = makeCard(
            showsOnboarding: true, savedDates: [clock, clock, clock])
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        card.view.layoutIfNeeded()

        XCTAssertEqual(
            actionButtons(in: card).compactMap(\.accessibilityLabel),
            [
                OnboardingStrings.Intro.safariAction.value(),
                OnboardingStrings.Intro.shortcutAction.value(),
            ])
    }

    /// A retired lesson's slot goes to email — on the completed card, which is
    /// where a three-save user actually is.
    func testEmailTakesTheSlotACompletedLessonGivesUp() throws {
        let store = makeStore()
        store.markSafariSetupHandled()
        store.retireCompletedSetupButtons()

        let card = makeCard(
            showsOnboarding: false,
            savedDates: [clock, clock, clock],
            store: store)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        card.view.layoutIfNeeded()

        let buttons = actionButtons(in: card)
        XCTAssertEqual(
            buttons.compactMap(\.accessibilityLabel),
            [
                OnboardingStrings.Intro.shortcutAction.value(),
                OnboardingStrings.Intro.emailAction.value(),
            ])
        XCTAssertNotNil(buttons.last?.configuration?.image)
        // Still stacked up from the paste row, headline or no headline.
        let paste = try XCTUnwrap(card.view.descendant(
            identifier: OnboardingStrings.Accessibility.introPaste.value()))
        XCTAssertLessThan(buttons[1].frame.maxY, paste.frame.minY)
        XCTAssertLessThan(buttons[0].frame.maxY, buttons[1].frame.minY)
    }

    /// Skipping is not finishing: the button stays, and it keeps outranking the
    /// email nudge.
    func testASkippedLessonKeepsItsButtonAndStillOutranksEmail() {
        let store = makeStore()
        store.markSafariSetupHandled(outcome: .skipped)
        store.markSaveSetupHandled()
        store.retireCompletedSetupButtons()

        XCTAssertFalse(store.isSafariSetupButtonRetired)
        XCTAssertTrue(store.isSaveSetupButtonRetired)

        let card = makeCard(
            showsOnboarding: false,
            savedDates: [clock, clock, clock],
            store: store)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        card.view.layoutIfNeeded()

        XCTAssertEqual(
            actionButtons(in: card).compactMap(\.accessibilityLabel),
            [
                OnboardingStrings.Intro.safariAction.value(),
                OnboardingStrings.Intro.emailAction.value(),
            ])
    }

    func testEmailIsNeverOfferedWithoutAnAccountToConnectOrWithOneAlready() {
        for card in [
            // Downloader and Price Tracker connect no account at all.
            makeCard(
                showsOnboarding: false,
                savedDates: [clock, clock, clock],
                app: .downloader),
            // Already connected: there is nothing to nudge.
            makeCard(
                showsOnboarding: false,
                savedDates: [clock, clock, clock],
                emailConnected: true),
        ] {
            card.loadViewIfNeeded()
            card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
            card.view.layoutIfNeeded()
            XCTAssertFalse(
                actionButtons(in: card).contains {
                    $0.accessibilityLabel
                        == OnboardingStrings.Intro.emailAction.value()
                })
        }
    }

    func testTheEmailButtonLaunchesTheSignInFlow() throws {
        let previous = UtilCardContentViewController.emailSetupLauncher
        defer { UtilCardContentViewController.emailSetupLauncher = previous }
        var launchedFrom: UIViewController?
        UtilCardContentViewController.emailSetupLauncher = { launchedFrom = $0 }

        let store = makeStore()
        store.markSafariSetupHandled()
        store.markSaveSetupHandled()
        store.retireCompletedSetupButtons()
        let card = makeCard(
            showsOnboarding: false,
            savedDates: [clock, clock, clock],
            store: store)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        card.view.layoutIfNeeded()

        let email = try XCTUnwrap(actionButtons(in: card).first)
        XCTAssertEqual(
            email.accessibilityLabel, OnboardingStrings.Intro.emailAction.value())
        email.sendActions(for: .touchUpInside)

        XCTAssertTrue(launchedFrom === card)
    }

    /// The email nudge arrives live: the third save reflows the card without a
    /// relaunch.
    func testTheThirdSaveBringsTheEmailButtonIn() {
        let store = makeStore()
        store.markSafariSetupHandled()
        store.markSaveSetupHandled()
        store.retireCompletedSetupButtons()
        var saves: [Date] = []
        let card = UtilCardContentViewController(
            showsOnboarding: false,
            configuration: .configuration(
                for: .reader, saveSetupMode: .actionButtonShortcut),
            onboardingStore: store,
            weeklyStore: weekly,
            app: .reader,
            now: { self.clock },
            hasSaves: { !saves.isEmpty },
            savedURLStrings: { [] },
            savedDates: { saves },
            isEmailConnected: { false },
            saveHandler: { _, _, _, completion in completion(true) })
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        card.view.layoutIfNeeded()
        XCTAssertTrue(actionButtons(in: card).isEmpty)

        saves = [clock, clock, clock]
        NotificationCenter.default.post(name: .readingListChanged, object: nil)
        card.view.layoutIfNeeded()

        XCTAssertEqual(
            actionButtons(in: card).compactMap(\.accessibilityLabel),
            [OnboardingStrings.Intro.emailAction.value()])
    }

    // MARK: - An already-saved weekly recommendation

    func testWeeklyRowReadsAsAnsweredWhenItsURLIsAlreadySaved() throws {
        seedWeekly(.article, url: "https://example.com/weekly", title: "A Read")
        let card = makeCard(
            showsOnboarding: true,
            savedURLStrings: ["https://example.com/weekly"])
        card.loadViewIfNeeded()

        let weekly = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.saveOfTheWeek") as? UtilURLRow)
        XCTAssertTrue(weekly.isShownAsSaved)
        XCTAssertLessThan(weekly.alpha, 1)
    }

    func testWeeklyRowIsOfferedPlainlyWhenNothingHasSavedItYet() throws {
        seedWeekly(.article, url: "https://example.com/weekly", title: "A Read")
        let card = makeCard(showsOnboarding: true, savedURLStrings: [])
        card.loadViewIfNeeded()

        let weekly = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.saveOfTheWeek") as? UtilURLRow)
        XCTAssertFalse(weekly.isShownAsSaved)
        XCTAssertEqual(weekly.alpha, 1)
    }

    func testTheRowAppearsWithASeededStoreInTheCompletedVariantToo() {
        seedWeekly(.article, url: "https://example.com/a", title: "A Read")
        let card = makeCard(showsOnboarding: false)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()
        XCTAssertNotNil(card.view.descendant(identifier: "utilCard.saveOfTheWeek"))
    }

    func testAnExpiredEntryIsNoEntry() {
        seedWeekly(.article, url: "https://example.com/a", title: "A Read", daysOld: 31)
        let card = makeCard(showsOnboarding: false)
        card.loadViewIfNeeded()
        XCTAssertNil(card.view.descendant(identifier: "utilCard.saveOfTheWeek"))
    }

    func testTappingTheWeeklyRowHandsItsStoredURLToTheDeck() throws {
        seedWeekly(.article, url: "https://example.com/weekly", title: "A Read")
        var savedURL: String?
        var savedSource: CaptureSource?
        let card = makeCard(showsOnboarding: true) { url, source, _, completion in
            savedURL = url
            savedSource = source
            completion(true)
        }
        card.loadViewIfNeeded()

        let row = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.saveOfTheWeek") as? UIControl)
        row.sendActions(for: .touchUpInside)

        XCTAssertEqual(savedURL, "https://example.com/weekly")
        XCTAssertEqual(savedSource, .manual)
    }

    /// The flag is a band across the row's top, not a sticker on the artwork —
    /// it used to overhang the thumbnail by a few points on purpose.
    func testTheCornerFlagClearsTheArtworkItLabels() throws {
        seedWeekly(.article, url: "https://example.com/a", title: "A Read")
        let card = makeCard(showsOnboarding: false, app: .reader)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()

        let row = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.saveOfTheWeek"))
        let flag = try XCTUnwrap(
            row.descendant(identifier: "utilCard.weeklyRibbon"))
        let artwork = try XCTUnwrap(row.descendants(of: UIImageView.self).first)

        XCTAssertEqual(row.bounds.height, UtilCardLayout.weeklyRowHeight)
        XCTAssertEqual(flag.frame.height, WeeklyRibbonView.height)
        XCTAssertLessThanOrEqual(flag.frame.maxY, artwork.frame.minY)
        // And the artwork is still centred in the row: at this height clearing
        // the flag costs it nothing.
        XCTAssertEqual(
            artwork.frame.midY, row.bounds.midY, accuracy: 0.5)
    }

    /// The trailing edge is ONE arc: it leaves the bottom edge and rises to the
    /// top without turning back, which is exactly what the old swallowtail did.
    func testTheCornerFlagsTrailingEdgeIsOneArcRatherThanANotch() throws {
        let rect = CGRect(x: 0, y: 0, width: 120, height: WeeklyRibbonView.height)
        let path = WeeklyRibbonView.pennantPath(in: rect)
        let edges = stride(from: rect.minY + 0.5, to: rect.maxY, by: 1)
            .map { trailingEdgeX(of: path, at: $0, in: rect) }

        XCTAssertGreaterThan(edges.count, 10)
        for (upper, lower) in zip(edges, edges.dropFirst()) {
            XCTAssertLessThanOrEqual(lower, upper + 0.01, "the edge doubled back")
        }
        // It reaches the top edge, and has visibly swept in by the bottom one.
        let top = try XCTUnwrap(edges.first)
        let bottom = try XCTUnwrap(edges.last)
        XCTAssertEqual(top, rect.maxX, accuracy: 1)
        XCTAssertGreaterThan(top - bottom, 6)
    }

    /// The fill used to be the palette at full strength — bright enough that two
    /// of the four had to letter in black to stay legible. Dimmed into the row's
    /// own black, every one of them is a quiet patch that carries white.
    func testEveryAppsFlagIsDimmedFarEnoughBelowItsLettering() {
        let surfaces: [LunaSurfacePalette.Surface] =
            [.luna, .reader, .downloader, .priceTracker]
        for surface in surfaces {
            let fill = WeeklyRibbonView.fillColor(for: surface)
            let base = LunaSurfacePalette.baseColor(for: surface)
            XCTAssertLessThan(
                relativeLuminance(fill), relativeLuminance(base) * 0.4,
                "\(surface) flag is still as bright as its palette")
            XCTAssertGreaterThan(
                contrastRatio(WeeklyRibbonView.textColor, fill), 4.5,
                "\(surface) flag cannot carry white lettering")
        }
    }

    func testTheRowAppearsLiveWhenTheStoreGainsAValue() {
        let card = makeCard(showsOnboarding: false)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()
        XCTAssertNil(card.view.descendant(identifier: "utilCard.saveOfTheWeek"))

        seedWeekly(.article, url: "https://example.com/a", title: "A Read")
        // The store's change notification is delivered on the main queue.
        let deadline = Date().addingTimeInterval(2)
        while card.view.descendant(identifier: "utilCard.saveOfTheWeek") == nil,
              Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        card.view.layoutIfNeeded()
        XCTAssertNotNil(card.view.descendant(identifier: "utilCard.saveOfTheWeek"))
    }

    /// A faceted app never renders another app's kind, even if the shared store
    /// has one (the central app wrote it).
    func testAFacetedAppIgnoresAForeignKind() {
        seedWeekly(.media, url: "https://video.example/v", title: "A Clip")
        let reader = makeCard(showsOnboarding: false, app: .reader)
        reader.loadViewIfNeeded()
        XCTAssertNil(reader.view.descendant(identifier: "utilCard.saveOfTheWeek"))

        let central = makeCard(showsOnboarding: false, app: .luna)
        central.loadViewIfNeeded()
        XCTAssertNotNil(central.view.descendant(identifier: "utilCard.saveOfTheWeek"))
    }

    // MARK: - The completed card's horizon

    /// Post-onboarding the pick of the week rides at its own seat, half the
    /// height of the one the intro headline had — it is not the first entry of
    /// the history list, and the seam below it is far wider than the one
    /// between two history rows.
    func testCompletedCardSeatsTheWeeklyRowAtHalfTheHeadlinesSeatAboveTheRecents() throws {
        seedWeekly(.article, url: "https://example.com/weekly", title: "A Read")
        let card = makeCard(
            showsOnboarding: false,
            recents: [recent("a"), recent("b")])
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
        card.view.layoutIfNeeded()

        let weeklyRow = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.saveOfTheWeek"))
        let weekly = weeklyRow.convert(weeklyRow.bounds, to: card.view)
        let recents = visibleRecentRows(in: card)
        XCTAssertEqual(recents.count, 2)

        XCTAssertEqual(
            weekly.minY,
            (card.view.bounds.height * UtilCardLayout.weeklyTopRatio).rounded())
        XCTAssertEqual(
            UtilCardLayout.weeklyTopRatio, UtilCardLayout.headlineTopRatio / 2)
        XCTAssertGreaterThan(recents[0].frame.minY, weekly.maxY)
        let seam = recents[0].frame.minY - weekly.maxY
        let betweenRecents = recents[1].frame.minY - recents[0].frame.maxY
        XCTAssertGreaterThan(seam, betweenRecents)
    }

    /// No live pick, no seat to keep: history takes the whole card.
    func testCompletedCardWithoutAWeeklyPickLetsTheRecentsReclaimTheTop() throws {
        let card = makeCard(showsOnboarding: false, recents: [recent("a")])
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
        card.view.layoutIfNeeded()

        XCTAssertNil(card.view.descendant(identifier: "utilCard.saveOfTheWeek"))
        let recents = visibleRecentRows(in: card)
        XCTAssertEqual(recents.first?.frame.minY, UtilCardLayout.recentsTop)
    }

    /// Luna's own pick wears the app's colour; raw history stays neutral.
    func testTheWeeklyRowIsDressedApartFromAHistoryRow() throws {
        seedWeekly(.article, url: "https://example.com/weekly", title: "A Read")
        let card = makeCard(showsOnboarding: false, recents: [recent("a")])
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
        card.view.layoutIfNeeded()

        let weeklyRow = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.saveOfTheWeek") as? UtilURLRow)
        let recentRow = try XCTUnwrap(visibleRecentRows(in: card).first)
        // The save transition's artwork is the row's own dressing, flattened.
        let weekly = try XCTUnwrap(
            weeklyRow.makeUtilCardSaveTransitionArtwork(in: card.view))
        let history = try XCTUnwrap(
            recentRow.makeUtilCardSaveTransitionArtwork(in: card.view))

        XCTAssertNotNil(weekly.rimTint)
        XCTAssertNil(history.rimTint)
        XCTAssertNotEqual(weekly.backgroundColor, history.backgroundColor)
        let traits = card.view.traitCollection
        XCTAssertNotEqual(
            weekly.subtitle?.textColor?.resolvedColor(with: traits),
            history.subtitle?.textColor?.resolvedColor(with: traits))
    }

    private func visibleRecentRows(
        in card: UtilCardContentViewController
    ) -> [UtilURLRow] {
        card.view.descendants(of: UtilURLRow.self)
            .filter { $0.accessibilityIdentifier == "utilCard.recent" && !$0.isHidden }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func recent(_ path: String) -> RecentURLPreview {
        RecentURLPreview(
            urlString: "https://recent.example/\(path)",
            title: "Recent \(path)",
            subtitle: "recent.example",
            kind: .article,
            imageData: nil)
    }

    // MARK: - Where downloads are stored

    /// The line tops the block whatever else is in it, and it takes the recents'
    /// room — its options open over the space they would occupy.
    func testStorageLineTopsTheBlockAndStandsDownTheRecents() throws {
        seedWeekly(.article, url: "https://example.com/weekly", title: "A Read")
        let card = makeCard(
            showsOnboarding: false,
            savedDates: [clock, clock, clock],
            recents: [recent("a"), recent("b")],
            storageChoice: FakeDownloadStorageChoice())
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
        card.view.layoutIfNeeded()

        let chooser = try XCTUnwrap(storageChooser(in: card))
        let buttons = actionButtons(in: card)
        XCTAssertFalse(buttons.isEmpty)
        XCTAssertLessThan(chooser.frame.maxY, buttons[0].frame.minY)
        let paste = try XCTUnwrap(card.view.descendant(
            identifier: OnboardingStrings.Accessibility.introPaste.value()))
        XCTAssertLessThan(chooser.frame.maxY, paste.frame.minY)
        XCTAssertTrue(visibleRecentRows(in: card).isEmpty)
    }

    /// It is not a setup lesson: it does not wait for the first run to be over,
    /// and it does not compete for the block's two-button budget.
    func testStorageLineBelongsToBothCardVariants() {
        for showsOnboarding in [true, false] {
            let card = makeCard(
                showsOnboarding: showsOnboarding,
                storageChoice: FakeDownloadStorageChoice())
            card.loadViewIfNeeded()
            card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
            card.view.layoutIfNeeded()

            XCTAssertNotNil(storageChooser(in: card))
            XCTAssertEqual(actionButtons(in: card).count, 2)
        }
    }

    func testStorageSelectorCentersItsIconTextAndIndicatorWithASquircleRim() throws {
        let card = makeCard(
            showsOnboarding: false,
            storageChoice: FakeDownloadStorageChoice())
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
        card.view.layoutIfNeeded()

        let selector = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.storage.selector") as? UIControl)
        let images = selector.subviews.compactMap { $0 as? UIImageView }
        let icon = try XCTUnwrap(images.first)
        let indicator = try XCTUnwrap(images.last)
        XCTAssertEqual(
            (icon.frame.minX + indicator.frame.maxX) / 2,
            selector.bounds.midX,
            accuracy: 1)
        XCTAssertEqual(icon.layer.borderWidth, 1)
        XCTAssertEqual(
            icon.layer.cornerRadius,
            icon.bounds.height * LunaAppIconImage.cornerRadiusRatio,
            accuracy: 0.01)
    }

    func testStorageLineIsAbsentWithoutADownloadingAppOrOnceItIsAnswered() {
        for choice in [
            // Reader and Price Tracker install none.
            nil,
            FakeDownloadStorageChoice(isUnanswered: false),
        ] as [FakeDownloadStorageChoice?] {
            let card = makeCard(showsOnboarding: false, storageChoice: choice)
            card.loadViewIfNeeded()
            card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
            card.view.layoutIfNeeded()

            XCTAssertNil(storageChooser(in: card))
        }
    }

    /// The line shows the setting as it stands, which on a fresh install is
    /// Luna's Photos default rather than anything the user has said.
    func testStorageLineShowsTheSettingAsItStands() throws {
        for usesPhotos in [true, false] {
            let card = makeCard(
                showsOnboarding: false,
                storageChoice: FakeDownloadStorageChoice(usesPhotos: usesPhotos))
            card.loadViewIfNeeded()
            card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
            card.view.layoutIfNeeded()

            let chooser = try XCTUnwrap(storageChooser(in: card))
            XCTAssertEqual(chooser.selection, usesPhotos ? .photos : .luna)
        }
    }

    /// Both options open over the card, and the SELECTED one lands exactly where
    /// the collapsed selector was — that is what "in place" means here.
    func testTappingTheSelectorOpensBothOptionsOverTheCardInPlace() throws {
        let card = makeCard(
            showsOnboarding: false,
            storageChoice: FakeDownloadStorageChoice(usesPhotos: true))
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
        card.view.layoutIfNeeded()

        let chooser = try XCTUnwrap(storageChooser(in: card))
        XCTAssertNil(card.view.descendant(identifier: "utilCard.storage.option.luna"))

        try tapSelector(in: card)
        XCTAssertTrue(chooser.isExpanded)
        let luna = try XCTUnwrap(card.view.descendant(
            identifier: "utilCard.storage.option.luna"))
        let photos = try XCTUnwrap(card.view.descendant(
            identifier: "utilCard.storage.option.photos"))
        let selector = try XCTUnwrap(card.view.descendant(
            identifier: "utilCard.storage.selector"))
        XCTAssertEqual(
            photos.convert(photos.bounds, to: card.view).minY,
            selector.convert(selector.bounds, to: card.view).minY,
            accuracy: 0.5)
        XCTAssertLessThan(
            luna.convert(luna.bounds, to: card.view).minY,
            photos.convert(photos.bounds, to: card.view).minY)
    }

    /// The setting follows the system's answer, never leads it: a refusal leaves
    /// the line reading "in Luna" rather than promising a destination Luna
    /// cannot write to.
    func testARefusedPhotosRequestLeavesTheLineOnLuna() throws {
        let choice = FakeDownloadStorageChoice(usesPhotos: false, photosOutcome: .refused)
        let card = makeCard(showsOnboarding: false, storageChoice: choice)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
        card.view.layoutIfNeeded()

        try tapOption("photos", in: card)

        XCTAssertEqual(choice.photosRequests, 1)
        XCTAssertEqual(try XCTUnwrap(storageChooser(in: card)).selection, .luna)
    }

    /// iOS shows its Photos prompt once. The second attempt cannot ask, so the
    /// card opens Luna's own page in Settings instead of failing silently.
    func testASecondPhotosAttemptOpensLunasOwnSettingsPage() throws {
        var openedSettings = 0
        let choice = FakeDownloadStorageChoice(
            usesPhotos: false, photosOutcome: .refusedBefore)
        let card = makeCard(
            showsOnboarding: false,
            storageChoice: choice,
            openSystemSettings: { openedSettings += 1 })
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
        card.view.layoutIfNeeded()

        try tapOption("photos", in: card)

        XCTAssertEqual(openedSettings, 1)
        XCTAssertEqual(try XCTUnwrap(storageChooser(in: card)).selection, .luna)
    }

    func testChoosingLunaAppliesItAndClosesTheOptions() throws {
        let choice = FakeDownloadStorageChoice(usesPhotos: true)
        let card = makeCard(showsOnboarding: false, storageChoice: choice)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
        card.view.layoutIfNeeded()

        try tapOption("luna", in: card)

        XCTAssertTrue(choice.choseLuna)
        let chooser = try XCTUnwrap(storageChooser(in: card))
        XCTAssertEqual(chooser.selection, .luna)
        XCTAssertFalse(chooser.isExpanded)
    }

    private func storageChooser(
        in card: UtilCardContentViewController
    ) -> UtilCardStorageChooserView? {
        card.view.descendants(of: UtilCardStorageChooserView.self).first
    }

    private func tapSelector(in card: UtilCardContentViewController) throws {
        let selector = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.storage.selector") as? UIControl)
        selector.sendActions(for: .touchUpInside)
    }

    private func tapOption(_ name: String, in card: UtilCardContentViewController) throws {
        try tapSelector(in: card)
        let option = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.storage.option.\(name)") as? UIControl)
        option.sendActions(for: .touchUpInside)
    }

    // MARK: - Weekly helpers

    private func seedWeekly(
        _ kind: WeeklySaveKind, url: String, title: String, daysOld: Int = 1
    ) {
        let key = Curve25519.Signing.PrivateKey()
        let save = try! WeeklySigning.sign(
            kind: kind, urlString: url,
            date: clock.addingTimeInterval(-Double(daysOld) * 86_400),
            privateKey: key)
        weekly.setDisplay(
            WeeklySaveDisplay(
                save: save, title: title, subtitleHost: "example.com", imageData: nil),
            for: kind)
    }

    /// The x of the flag's trailing edge at one height, found by walking in from
    /// the rect's own right edge until the shape claims the point.
    private func trailingEdgeX(
        of path: UIBezierPath, at y: CGFloat, in rect: CGRect
    ) -> CGFloat {
        var x = rect.maxX
        while x > rect.minX {
            if path.contains(CGPoint(x: x, y: y)) { return x }
            x -= 0.25
        }
        return rect.minX
    }

    /// WCAG relative luminance, so "less bright" is measured rather than eyeballed.
    private func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        let linear: (CGFloat) -> CGFloat = { channel in
            channel <= 0.03928
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private func contrastRatio(_ one: UIColor, _ other: UIColor) -> CGFloat {
        let a = relativeLuminance(one)
        let b = relativeLuminance(other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    // MARK: - A save answers the first run

    func testASaveMadeSinceOnboardingBeganCompletesIt() {
        var newestSave: Date?
        let store = makeStore(newestSaveDate: { newestSave })
        store.beginOnboardingIfNeeded(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertFalse(store.isCompleted)

        newestSave = Date(timeIntervalSince1970: 1_100)
        XCTAssertTrue(store.markCompletedIfSavedSinceOnboardingStart())
        XCTAssertTrue(store.isCompleted)
    }

    func testSavesOlderThanTheJourneyDoNotAnswerIt() {
        let store = makeStore(newestSaveDate: { Date(timeIntervalSince1970: 900) })
        store.beginOnboardingIfNeeded(now: Date(timeIntervalSince1970: 1_000))

        XCTAssertFalse(store.markCompletedIfSavedSinceOnboardingStart())
        XCTAssertFalse(store.isCompleted)
    }

    /// A reset while the deck is full: the first-run card comes back on the next
    /// launch — the saves already there belong to the previous journey — and
    /// stays until a NEW save arrives.
    func testResettingWithSavesPresentShowsTheFirstRunCardUntilTheNextSave() {
        var newestSave: Date? = Date(timeIntervalSince1970: 1_500)
        let store = makeStore(newestSaveDate: { newestSave })
        store.beginOnboardingIfNeeded(now: Date(timeIntervalSince1970: 1_000))
        store.markCompletedIfSavedSinceOnboardingStart()
        XCTAssertTrue(store.isCompleted)

        store.resetCompletion(now: Date(timeIntervalSince1970: 2_000))
        XCTAssertFalse(store.isCompleted)
        XCTAssertFalse(store.markCompletedIfSavedSinceOnboardingStart())

        newestSave = Date(timeIntervalSince1970: 2_100)
        XCTAssertTrue(store.markCompletedIfSavedSinceOnboardingStart())
        XCTAssertTrue(store.isCompleted)
    }

    /// The verdict is latched, not derived: deleting the save that answered the
    /// first run does not bring it back.
    func testDeletingTheAnsweringSaveDoesNotReopenOnboarding() {
        var newestSave: Date? = Date(timeIntervalSince1970: 1_100)
        let store = makeStore(newestSaveDate: { newestSave })
        store.beginOnboardingIfNeeded(now: Date(timeIntervalSince1970: 1_000))
        store.markCompletedIfSavedSinceOnboardingStart()

        newestSave = nil
        XCTAssertTrue(store.isCompleted)
    }

    /// The save lesson runs the REAL share surface, so it really does write a
    /// row. That row must never answer the first run: the app would be completing
    /// its own onboarding on the strength of a rehearsal it played to itself.
    func testTheSaveLessonsOwnRehearsalNeverAnswersTheFirstRun() {
        let rehearsal = UUID()
        let other = UUID()
        var saves: [UUID: Date] = [
            rehearsal: Date(timeIntervalSince1970: 1_100),
        ]
        let store = makeStore { excluded in
            saves.filter { $0.key != excluded }.values.max()
        }
        store.beginOnboardingIfNeeded(now: Date(timeIntervalSince1970: 1_000))

        store.recordTemporarySave(identifier: rehearsal)
        XCTAssertEqual(store.temporarySaveIdentifier, rehearsal)
        XCTAssertFalse(store.markCompletedIfSavedSinceOnboardingStart())
        XCTAssertFalse(store.isCompleted)

        // A save from anywhere ELSE, while the rehearsal is still on disk, still
        // answers it.
        saves[other] = Date(timeIntervalSince1970: 1_200)
        XCTAssertTrue(store.markCompletedIfSavedSinceOnboardingStart())
        XCTAssertTrue(store.isCompleted)

        store.clearTemporarySaveIdentifier()
        XCTAssertNil(store.temporarySaveIdentifier)
    }

    func testOnboardingStartIsStampedOnlyOnce() {
        let store = makeStore(newestSaveDate: { nil })
        store.beginOnboardingIfNeeded(now: Date(timeIntervalSince1970: 1_000))
        store.beginOnboardingIfNeeded(now: Date(timeIntervalSince1970: 5_000))

        XCTAssertEqual(store.onboardingStartDate, Date(timeIntervalSince1970: 1_000))
    }

    func testAnAlreadyCompletedAppNeverStartsAJourney() {
        let store = makeStore(newestSaveDate: { nil })
        store.markCompleted()

        store.beginOnboardingIfNeeded(now: Date(timeIntervalSince1970: 9_000))

        XCTAssertNil(store.onboardingStartDate)
    }

    private func makeStore(
        newestSaveDate: @escaping () -> Date?
    ) -> AppOnboardingStore {
        makeStore { _ in newestSaveDate() }
    }

    private func makeStore(
        newestSaveDate: @escaping (UUID?) -> Date?
    ) -> AppOnboardingStore {
        AppOnboardingStore(
            app: .reader,
            defaults: defaults,
            setupStatusStore: LunaSetupStatusStore(defaults: defaults),
            newestSaveDate: newestSaveDate)
    }

    private func makeStore(
        saveSetupMode: OnboardingSaveSetupMode = .actionButtonShortcut
    ) -> AppOnboardingStore {
        AppOnboardingStore(
            app: .reader,
            defaults: defaults,
            setupStatusStore: LunaSetupStatusStore(defaults: defaults),
            saveSetupMode: saveSetupMode)
    }

    /// The setup block's own buttons, top to bottom — the card's direct button
    /// children, so the paste control and the rows' controls stay out of it.
    private func actionButtons(in card: UtilCardContentViewController) -> [UIButton] {
        card.view.descendants(of: UIButton.self)
            .filter { $0.superview === card.view }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func orSeparator(in card: UtilCardContentViewController) -> UIView? {
        card.view.descendant(
            identifier: OnboardingStrings.Accessibility.introOr.value())
    }

    private func makeCard(
        showsOnboarding: Bool,
        animatesIntro: Bool = false,
        hasSaves: Bool = false,
        savedURLStrings: Set<String> = [],
        savedDates: [Date] = [],
        emailConnected: Bool = false,
        store: AppOnboardingStore? = nil,
        app: LunaApp = .reader,
        saveSetupMode: OnboardingSaveSetupMode = .actionButtonShortcut,
        recents: [RecentURLPreview] = [],
        storageChoice: (any DownloadStorageChoosing)? = nil,
        openSystemSettings: @escaping () -> Void = {},
        saveHandler: UtilCardContentViewController.SaveHandler? = nil
    ) -> UtilCardContentViewController {
        UtilCardContentViewController(
            showsOnboarding: showsOnboarding,
            animatesIntro: animatesIntro,
            configuration: .configuration(
                for: app,
                saveSetupMode: saveSetupMode),
            onboardingStore: store ?? makeStore(saveSetupMode: saveSetupMode),
            weeklyStore: weekly,
            app: app,
            now: { self.clock },
            hasSaves: { hasSaves },
            savedURLStrings: { savedURLStrings },
            savedDates: { savedDates },
            isEmailConnected: { emailConnected },
            recentMatches: { recents },
            storageChoice: storageChoice,
            openSystemSettings: openSystemSettings,
            saveHandler: saveHandler ?? { _, _, _, completion in completion(true) })
    }
}

/// A download-storage choice the test drives directly, standing in for
/// `MediaUtilCardStorageChoice` (whose own behaviour — the permission request,
/// the revert, the inline age — is pinned in `AutoDownloadSettingsTests`).
@MainActor
final class FakeDownloadStorageChoice: DownloadStorageChoosing {
    var isUnanswered: Bool
    var usesPhotos: Bool
    /// What a Photos request comes back with, and how many were made.
    var photosOutcome: DownloadStoragePhotosOutcome
    private(set) var photosRequests = 0
    private(set) var choseLuna = false

    init(
        isUnanswered: Bool = true,
        usesPhotos: Bool = true,
        photosOutcome: DownloadStoragePhotosOutcome = .granted
    ) {
        self.isUnanswered = isUnanswered
        self.usesPhotos = usesPhotos
        self.photosOutcome = photosOutcome
    }

    func chooseInLuna() {
        choseLuna = true
        usesPhotos = false
    }

    func choosePhotos(completion: @escaping (DownloadStoragePhotosOutcome) -> Void) {
        photosRequests += 1
        if photosOutcome == .granted { usesPhotos = true } else { usesPhotos = false }
        completion(photosOutcome)
    }
}

private extension UIView {
    func descendant(identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        return subviews.lazy.compactMap { $0.descendant(identifier: identifier) }.first
    }

    func descendants<View: UIView>(of type: View.Type) -> [View] {
        subviews.flatMap { view -> [View] in
            let current = (view as? View).map { [$0] } ?? []
            return current + view.descendants(of: type)
        }
    }
}
