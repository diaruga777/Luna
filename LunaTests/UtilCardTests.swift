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

    func testAnEmptyWeeklyStoreShowsNoRowAndGivesItsSpaceBack() throws {
        let withoutRow = makeCard(showsOnboarding: true)
        withoutRow.loadViewIfNeeded()
        withoutRow.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        withoutRow.view.layoutIfNeeded()
        XCTAssertNil(withoutRow.view.descendant(identifier: "utilCard.saveOfTheWeek"))
        let collapsedSafariY = try XCTUnwrap(
            withoutRow.view.descendants(of: UIButton.self).first).frame.minY

        seedWeekly(.article, url: "https://example.com/a", title: "A Read")
        let withRow = makeCard(showsOnboarding: true)
        withRow.loadViewIfNeeded()
        withRow.view.frame = CGRect(x: 0, y: 0, width: 350, height: 620)
        withRow.view.layoutIfNeeded()
        XCTAssertNotNil(withRow.view.descendant(identifier: "utilCard.saveOfTheWeek"))
        let expandedSafariY = try XCTUnwrap(
            withRow.view.descendants(of: UIButton.self).first).frame.minY
        XCTAssertGreaterThan(
            expandedSafariY, collapsedSafariY,
            "The setup buttons must move up when there is no weekly row")
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

    // MARK: - Helpers

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

    private func makeCard(
        showsOnboarding: Bool,
        store: AppOnboardingStore? = nil,
        app: LunaApp = .reader,
        saveHandler: UtilCardContentViewController.SaveHandler? = nil
    ) -> UtilCardContentViewController {
        let resolvedStore = store ?? AppOnboardingStore(
            app: app,
            defaults: defaults,
            setupStatusStore: LunaSetupStatusStore(defaults: defaults))
        return UtilCardContentViewController(
            showsOnboarding: showsOnboarding,
            configuration: .configuration(for: app, saveSetupMode: .actionButtonShortcut),
            onboardingStore: resolvedStore,
            weeklyStore: weekly,
            app: app,
            now: { self.clock },
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
