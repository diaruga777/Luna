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

    private func makeCard(
        showsOnboarding: Bool,
        store: AppOnboardingStore? = nil
    ) -> UtilCardContentViewController {
        let resolvedStore = store ?? AppOnboardingStore(
            app: .reader,
            defaults: defaults,
            setupStatusStore: LunaSetupStatusStore(defaults: defaults))
        return UtilCardContentViewController(
            showsOnboarding: showsOnboarding,
            configuration: .configuration(
                for: .reader,
                saveSetupMode: .actionButtonShortcut),
            onboardingStore: resolvedStore,
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
