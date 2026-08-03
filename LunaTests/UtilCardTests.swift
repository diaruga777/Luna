//
//  UtilCardTests.swift
//  LunaTests
//

import CryptoKit
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
        let fragments = try XCTUnwrap(headline.growingLine?.fragments)
        XCTAssertTrue(fragments.stem.isFullyRevealed)
        XCTAssertTrue(fragments.tail.isFullyRevealed)
        XCTAssertTrue(fragments.period.isFullyConcealed)
    }

    func testIntroHeadlineWaitsBehindItsFrontOnTheLaunchItBelongsTo() throws {
        let card = makeCard(showsOnboarding: true, animatesIntro: true)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()

        let headline = try XCTUnwrap(
            card.view.descendants(of: OnboardingIntroHeadlineView.self).first)
        let fragments = try XCTUnwrap(headline.growingLine?.fragments)
        XCTAssertFalse(fragments.stem.isFullyRevealed)
        XCTAssertFalse(fragments.tail.isFullyRevealed)
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
    func testEmailTakesTheSlotACompletedLessonGivesUp() {
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

    func testTheSubtitleNamesTheAppsNounAndItsAgeTier() throws {
        seedWeekly(.article, url: "https://example.com/a", title: "A Read")
        let week = try XCTUnwrap(weeklyRowSubtitle(app: .reader))
        XCTAssertTrue(week.hasSuffix("Read of the week"), week)

        clock = clock.addingTimeInterval(10 * 86_400)
        let month = try XCTUnwrap(weeklyRowSubtitle(app: .reader))
        XCTAssertTrue(month.hasSuffix("Read of the month"), month)

        let central = try XCTUnwrap(weeklyRowSubtitle(app: .luna))
        XCTAssertTrue(central.hasSuffix("Save of the month"), central)
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

    private func weeklyRowSubtitle(app: LunaApp) -> String? {
        let card = makeCard(showsOnboarding: false, app: app)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()
        guard let row = card.view.descendant(identifier: "utilCard.saveOfTheWeek") else {
            return nil
        }
        return row.descendants(of: UILabel.self).compactMap(\.text)
            .first { $0.contains("•") }
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
            saveHandler: saveHandler ?? { _, _, _, completion in completion(true) })
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
