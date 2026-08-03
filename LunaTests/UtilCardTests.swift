//
//  UtilCardTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna

@MainActor
final class UtilCardTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "UtilCardTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        UIView.setAnimationsEnabled(true)
        super.tearDown()
    }

    func testOnboardingVariantAlwaysContainsWeeklySavePasteAndBothSetupButtons() {
        let card = makeCard(showsOnboarding: true)
        card.loadViewIfNeeded()
        card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        card.view.layoutIfNeeded()

        XCTAssertNotNil(card.view.descendant(identifier: "utilCard.saveOfTheWeek"))
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
        XCTAssertNotNil(nextLaunch.view.descendant(identifier: "utilCard.saveOfTheWeek"))
        XCTAssertNotNil(nextLaunch.view.descendant(
            identifier: OnboardingStrings.Accessibility.introPaste.value()))
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

        // Bottom-up: paste field, the seam, both setup actions.
        XCTAssertLessThan(separator.frame.maxY, paste.frame.minY)
        XCTAssertLessThan(buttons[1].frame.maxY, separator.frame.minY)
        XCTAssertLessThan(buttons[0].frame.maxY, buttons[1].frame.minY)
        // The headline is neither on the card's shoulder nor as low as the third
        // the standalone onboarding root used.
        XCTAssertGreaterThan(headline.frame.minY, card.view.bounds.height * 0.2)
        XCTAssertLessThan(headline.frame.minY, card.view.bounds.height / 3)
        XCTAssertGreaterThan(weekly.frame.minY, headline.frame.maxY)
        XCTAssertLessThan(weekly.frame.maxY, buttons[0].frame.minY)
    }

    // MARK: - An already-saved weekly recommendation

    func testWeeklyRowReadsAsAnsweredWhenItsURLIsAlreadySaved() throws {
        let card = makeCard(
            showsOnboarding: true,
            savedURLStrings: [UtilCardContentViewController.saveOfTheWeekURLString])
        card.loadViewIfNeeded()

        let weekly = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.saveOfTheWeek") as? UtilURLRow)
        XCTAssertTrue(weekly.isShownAsSaved)
        XCTAssertLessThan(weekly.alpha, 1)
    }

    func testWeeklyRowIsOfferedPlainlyWhenNothingHasSavedItYet() throws {
        let card = makeCard(showsOnboarding: true, savedURLStrings: [])
        card.loadViewIfNeeded()

        let weekly = try XCTUnwrap(
            card.view.descendant(identifier: "utilCard.saveOfTheWeek") as? UtilURLRow)
        XCTAssertFalse(weekly.isShownAsSaved)
        XCTAssertEqual(weekly.alpha, 1)
    }

    func testWeeklySaveUsesTheCanonicalLewisSocietyURL() {
        XCTAssertEqual(
            UtilCardContentViewController.saveOfTheWeekURLString,
            "https://www.lewissociety.org/innerring/")
    }

    func testTappingWeeklySaveHandsItsURLToTheDeck() throws {
        var savedURL: String?
        var savedSource: CaptureSource?
        let card = UtilCardContentViewController(
            showsOnboarding: true,
            configuration: .configuration(
                for: .reader,
                saveSetupMode: .actionButtonShortcut),
            onboardingStore: AppOnboardingStore(
                app: .reader,
                defaults: defaults,
                setupStatusStore: LunaSetupStatusStore(defaults: defaults)),
            saveHandler: { url, source, _, completion in
                savedURL = url
                savedSource = source
                completion(true)
            })
        card.loadViewIfNeeded()

        let weekly = try XCTUnwrap(card.view.descendant(
            identifier: "utilCard.saveOfTheWeek") as? UIControl)
        weekly.sendActions(for: .touchUpInside)

        XCTAssertEqual(savedURL, UtilCardContentViewController.saveOfTheWeekURLString)
        XCTAssertEqual(savedSource, .manual)
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
        store: AppOnboardingStore? = nil
    ) -> UtilCardContentViewController {
        UtilCardContentViewController(
            showsOnboarding: showsOnboarding,
            animatesIntro: animatesIntro,
            configuration: .configuration(
                for: .reader,
                saveSetupMode: .actionButtonShortcut),
            onboardingStore: store ?? makeStore(),
            hasSaves: { hasSaves },
            savedURLStrings: { savedURLStrings },
            saveHandler: { _, _, _, completion in completion(true) })
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
