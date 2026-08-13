//
//  OnboardingHandoffFullContentTests.swift
//  LunaTests
//

import LunaModels
import LunaReaderUI
import LunaStorage
import UIKit
import XCTest
@testable import Luna

/// The deck's cards open on the Phase-1 prefix and expand to the whole article
/// only when the carousel tells the centered card it is primary. Landing on the
/// deck straight out of onboarding must reach that promotion exactly as a cold
/// launch does — otherwise every card is stuck showing a few hundred characters
/// of its save until the app is force-quit.
/// The production root as this suite needs it: a FRESH article deck, kept so the
/// test can assert what the handed-off deck did with its centered card.
@MainActor
final class ArticleDeckOnboardingRoot: CompletedOnboardingRootMaking {
    private(set) var deck: ArticleCardsViewController?

    func makeCompletedRootViewController() -> UIViewController {
        let cards = ArticleCardsViewController()
        deck = cards
        return UINavigationController(rootViewController: cards)
    }
}

final class OnboardingHandoffFullContentTests: XCTestCase {

    override func tearDown() {
        SavesStore.shared.seedForTesting(items: [], contents: [:])
        super.tearDown()
    }

    /// Baseline: a deck that appears as the window's root promotes its centered
    /// card, so the card's reader completes the Phase-2 full-content swap.
    @MainActor
    func testDeckAsWindowRootLoadsFullContent() {
        seedLongArticle()
        let deck = ArticleCardsViewController()
        let window = makeWindow(rootViewController: UINavigationController(rootViewController: deck))
        defer { window.isHidden = true }

        waitUntil(
            firstScrollReader(in: deck)?.didLoadFullContentForTesting == true,
            timeout: 5,
            message: "a cold-launched deck must expand its centered card to the full article")
    }

    /// The regression: onboarding builds the production root, hands it to the
    /// window, and the deck lands already centered on a card. That card must
    /// still be promoted to primary.
    @MainActor
    func testDeckHandedOffFromOnboardingLoadsFullContent() throws {
        seedLongArticle()
        let suite = "OnboardingHandoffFullContentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AppOnboardingStore(app: .reader, defaults: defaults)
        let changed = Notification.Name("onboarding.handoff.\(UUID())")
        let content = ScriptedStoredContent(identifiers: [UUID()])
        let productionRoot = ArticleDeckOnboardingRoot()
        let onboarding = AppOnboardingViewController(
            configuration: .configuration(for: .reader),
            onboardingStore: store,
            completion: AppOnboardingCompletion(
                contentWatch: OnboardingContentWatch(
                    changeNotifications: [changed], content: content),
                root: productionRoot))
        let window = makeWindow(rootViewController: onboarding)
        defer { window.isHidden = true }

        // A save arriving while the intro is up ends onboarding and hands the
        // freshly built production root to the window. The content observer is
        // delivered on the main queue but hops through a `Task { @MainActor }`
        // before it reaches the controller, so this WAITS for the handoff
        // instead of assuming it lands inside a fixed pump: under full-suite
        // load that hop has been measured at ~360ms, which turned a passing
        // assertion into a race the suite lost as it grew.
        content.identifiers.insert(UUID())
        NotificationCenter.default.post(name: changed, object: nil)

        waitUntil(
            store.isCompleted && productionRoot.deck != nil,
            timeout: 5,
            message: "a save arriving while the intro is up must end onboarding and hand "
                + "a freshly built production root to the window")
        let cards = try XCTUnwrap(productionRoot.deck)
        waitUntil(
            firstScrollReader(in: cards)?.didLoadFullContentForTesting == true,
            timeout: 5,
            message: "the deck handed off from onboarding must expand its centered card "
                + "to the full article, not leave it on the Phase-1 prefix")
    }

    /// The path a user actually takes out of onboarding: both setup lessons
    /// finish, and the root handed to the window is the one PRELOADED behind the
    /// intro copy (mounted as a hidden child long before the handoff) rather than
    /// a freshly built one. Its deck must still expand the centered card.
    @MainActor
    func testPreloadedDeckHandedOffFromOnboardingLoadsFullContent() throws {
        seedLongArticle()
        let suite = "OnboardingHandoffFullContentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let productionRoot = ArticleDeckOnboardingRoot()
        let onboarding = AppOnboardingViewController(
            configuration: .configuration(for: .reader),
            onboardingStore: AppOnboardingStore(app: .reader, defaults: defaults),
            completion: AppOnboardingCompletion(root: productionRoot))
        let window = makeWindow(rootViewController: onboarding)
        defer { window.isHidden = true }

        // Preload the production root behind the intro, exactly as the reveal does.
        onboarding.firstIntroLineDidReveal()
        let deadline = Date().addingTimeInterval(5)
        while onboarding.savedRootViewControllerForTesting == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let root = try XCTUnwrap(onboarding.savedRootViewControllerForTesting)
        let cards = try XCTUnwrap(productionRoot.deck)

        // Finish: hand the preloaded root to the window.
        AppOnboardingCompletionTransition.run(in: window, to: root)

        waitUntil(
            firstScrollReader(in: cards)?.didLoadFullContentForTesting == true,
            timeout: 5,
            message: "the PRELOADED deck handed off at the end of onboarding must expand its "
                + "centered card to the full article, not leave it on the Phase-1 prefix")
    }

    // MARK: - Helpers

    private func seedLongArticle() {
        let item = SavedItem(
            seed: "onboarding-handoff",
            urlString: "https://example.com/onboarding-handoff",
            title: "Onboarding Handoff",
            dateAdded: Date(),
            state: .ready,
            wordCount: 480)
        SavesStore.shared.seedForTesting(
            items: [item],
            contents: [item.id: UITestFixtures.sampleArticleContent(title: "Onboarding Handoff")])
    }

    @MainActor
    private func makeWindow(rootViewController: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        rootViewController.view.layoutIfNeeded()
        return window
    }

    @MainActor
    private func firstScrollReader(in controller: UIViewController) -> ScrollReaderViewController? {
        if let reader = controller as? ScrollReaderViewController { return reader }
        for child in controller.children {
            if let found = firstScrollReader(in: child) { return found }
        }
        return nil
    }
}
