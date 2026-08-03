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
        let setup = LunaSetupStatusStore(defaults: defaults)
        let store = AppOnboardingStore(
            app: .reader,
            defaults: defaults,
            setupStatusStore: setup)
        let currentSession = makeCard(showsOnboarding: true, store: store)
        currentSession.loadViewIfNeeded()

        store.markSafariSetupHandled()
        store.markSaveSetupHandled()

        XCTAssertTrue(store.isCompleted)
        XCTAssertEqual(currentSession.view.descendants(of: UIButton.self).count, 2)

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

    /// A weekly value landing while the headline is still speaking takes its
    /// slot silently and joins the group fade instead of fading in on its own.
    func testAWeeklyValueArrivingMidSweepWaitsForTheGroupReveal() throws {
        let card = makeCard(showsOnboarding: true, animatesIntro: true)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()
        let host = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.weeklyHost"))
        XCTAssertTrue(host.isHidden)

        seedWeekly(.article, url: "https://example.com/a", title: "A Read")
        let deadline = Date().addingTimeInterval(2)
        while host.isHidden, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertFalse(host.isHidden, "The slot is claimed while invisible")
        XCTAssertEqual(host.alpha, 0, "Its alpha belongs to the group reveal")
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

    /// The noun lives in the corner flag, not in the subtitle — which is now the
    /// host and nothing else, so it has the whole row's width to spell it out.
    func testTheCornerFlagNamesTheAppsNounAndItsAgeTier() throws {
        seedWeekly(.article, url: "https://example.com/a", title: "A Read")
        let week = try XCTUnwrap(weeklyRowFlagText(app: .reader))
        XCTAssertEqual(week, "Read of the week")

        clock = clock.addingTimeInterval(10 * 86_400)
        let month = try XCTUnwrap(weeklyRowFlagText(app: .reader))
        XCTAssertEqual(month, "Read of the month")

        let central = try XCTUnwrap(weeklyRowFlagText(app: .luna))
        XCTAssertEqual(central, "Save of the month")
    }

    func testTheSubtitleIsTheHostAloneWithNoWeeklyPhraseBesideIt() {
        seedWeekly(.article, url: "https://example.com/a", title: "A Read")
        let hostLabels = weeklyRowLabelTexts(app: .reader)
            .filter { $0.contains("example.com") }
        XCTAssertEqual(hostLabels, ["example.com"])
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

    /// Post-onboarding the pick of the week keeps the seat the intro headline
    /// had — it is not the first entry of the history list, and the seam below it
    /// is wider than the one between two history rows.
    func testCompletedCardSeatsTheWeeklyRowWhereTheHeadlineStoodAboveTheRecents() throws {
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
            (card.view.bounds.height * UtilCardLayout.headlineTopRatio).rounded())
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

    private func weeklyRowLabelTexts(app: LunaApp) -> [String] {
        let card = makeCard(showsOnboarding: false, app: app)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()
        guard let row = card.view.descendant(identifier: "utilCard.saveOfTheWeek") else {
            return []
        }
        return row.descendants(of: UILabel.self).compactMap(\.text)
    }

    /// The corner flag's own text.
    private func weeklyRowFlagText(app: LunaApp) -> String? {
        let card = makeCard(showsOnboarding: false, app: app)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()
        return (card.view.descendant(identifier: "utilCard.weeklyRibbon")
            as? WeeklyRibbonView)?.text
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

    private func makeStore() -> AppOnboardingStore {
        AppOnboardingStore(
            app: .reader,
            defaults: defaults,
            setupStatusStore: LunaSetupStatusStore(defaults: defaults))
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
        store: AppOnboardingStore? = nil,
        app: LunaApp = .reader,
        recents: [RecentURLPreview] = [],
        saveHandler: UtilCardContentViewController.SaveHandler? = nil
    ) -> UtilCardContentViewController {
        UtilCardContentViewController(
            showsOnboarding: showsOnboarding,
            animatesIntro: animatesIntro,
            configuration: .configuration(
                for: app,
                saveSetupMode: .actionButtonShortcut),
            onboardingStore: store ?? makeStore(),
            weeklyStore: weekly,
            app: app,
            now: { self.clock },
            hasSaves: { hasSaves },
            savedURLStrings: { savedURLStrings },
            recentMatches: { recents },
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
