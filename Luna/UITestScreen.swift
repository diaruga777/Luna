//
//  UITestScreen.swift
//  Luna
//

import LunaReadingListUI
import LunaSocialUI
import LunaShareSurface
import LunaPriceUI
import LunaReaderUI
import LunaStorage
import LunaModels
import UIKit

#if DEBUG
/// A named screen the screenshot harness can deep-link to on launch via
/// `-uiTestScreen <rawValue>`. Coordinate-tapping is fragile across the many
/// device sizes the screenshot agent captures, so instead of navigating the UI
/// the agent asks the app to build the target screen directly as (or presented
/// over) the window's root.
///
/// Every case maps to the exact construction seam the unit tests use
/// (`ReaderViewController(item:content:…)`, `CatchUpViewController(unread:router:)`,
/// `ShareReaderViewController(url:mode:onDone:)`, etc.), so a deep-linked screen
/// renders the same content the snapshot tests assert on.
///
/// DEBUG-only and launch-arg-gated — production code paths never reference this.
/// See `claudedocs/ui-testing.md`.
enum UITestScreen: String, CaseIterable {
    // Reading list is reachable via `-uiTestState` alone, but these let the agent
    // request specific list-driven modals/pushes deterministically.
    case catchUp
    case friends
    case friendDetail
    case settings
    case priceTrackingEditor

    // Readers (built from a deterministic fixture article).
    case readerScroll
    case readerHighlight
    case readerRSVP
    case readerInlineHeader
    case readerNested

    // Reader-adjacent extension/host screens.
    case shareReaderArticle
    case shareMediaPlatform
    case actionReaderArticle

    // Catch-up showing only a price-tracker card (for verifying that card's layout).
    case priceCatchUp
}

/// Builds the forced root view controller for a deep-linked UI-test screen. Some
/// screens render directly as the root (or inside a nav controller); others are
/// modals that must be presented over a host once the window is on screen, so the
/// builder returns a host whose `viewDidAppear` presents the target.
enum UITestScreenBuilder {

    /// A deterministic fixture article + its content, matching `ReaderScreenTests`.
    private static var fixtureItem: ReadingListItem {
        ReadingListItem(seed: "uitest-reader", urlString: "https://example.com/reader",
                        title: "The Quiet Architecture of Everyday Things",
                        dateAdded: UITestFixtures.baseDate, state: .ready, wordCount: 480)
    }

    private static var fixtureContent: ArticleContent {
        UITestFixtures.sampleArticleContent(title: "The Quiet Architecture of Everyday Things")
    }

    /// Returns the root view controller for `screen`. The store has already been
    /// seeded by `UITestSeeder.applyIfNeeded()` before this is called.
    static func rootViewController(for screen: UITestScreen) -> UIViewController {
        switch screen {
        case .settings:
            return UINavigationController(rootViewController: SettingsViewController())

        case .friends:
            return UINavigationController(rootViewController: FriendsViewController())

        case .friendDetail:
            // No real friends are seeded; show the Friends list (its layout is the
            // testable surface). A dedicated detail fixture would need a keychain
            // identity, which the harness doesn't seed.
            return UINavigationController(rootViewController: FriendsViewController())

        case .priceTrackingEditor:
            let tracker = ReadingListStore.shared.items().first { $0.isPriceTracker }
            if let tracker {
                return UINavigationController(
                    rootViewController: PriceTrackingViewController(itemID: tracker.id))
            }
            return UINavigationController(rootViewController: ReadingListViewController())

        case .priceCatchUp:
            let router = ReadingListViewController()
            let host = UINavigationController(rootViewController: router)
            return PresentingHostViewController(host: host) { [weak router] in
                guard let router else { return nil }
                let trackers = ReadingListStore.shared.items().filter { $0.isPriceTracker }
                guard !trackers.isEmpty else { return nil }
                return CatchUpViewController(unread: trackers, router: router)
            }

        case .readerScroll:
            return UINavigationController(rootViewController: reader(forceMode: .scroll))
        case .readerHighlight:
            return UINavigationController(rootViewController: reader(forceMode: .highlight))
        case .readerRSVP:
            return UINavigationController(rootViewController: reader(forceMode: .rsvp))
        case .readerInlineHeader:
            let reader = ReaderViewController(
                item: fixtureItem, content: fixtureContent, forceMode: .scroll,
                persistsModePreference: false, marksOpenedOnLoad: false,
                inlineControlsHeader: true, inlineHeaderSubtitle: "Today · from alex")
            return UINavigationController(rootViewController: reader)
        case .readerNested:
            let reader = self.reader(forceMode: .scroll)
            let host = UINavigationController(rootViewController: reader)
            return PresentingHostViewController(host: host) {
                guard let linkedURL = URL(string: "https://example.com/linked-article") else {
                    return nil
                }
                let nested = SplitWebOverlayViewController(
                    url: linkedURL, shareProvider: nil,
                    sourcePoint: CGPoint(x: 226, y: 430),
                    outerURL: fixtureItem.url,
                    outerTitle: fixtureContent.title,
                    contentTop: reader.inlineReaderTopEdgeInWindow,
                    cardFrame: reader.inlineReaderCardFrameInWindow,
                    showsOuterContentBelow: reader.inlineReaderShowsOuterContentBelow)
                nested.onOpen = { [weak reader, weak nested] in
                    guard let nested else { return }
                    reader?.inlineReaderWillPresent(nested)
                }
                nested.onChromeStateChanged = { [weak reader, weak nested] in
                    guard let nested else { return }
                    reader?.inlineReaderWillPresent(nested)
                }
                nested.onDismiss = { [weak reader, weak nested] in
                    guard let nested else { return }
                    reader?.inlineReaderDidDismiss(nested)
                }
                return nested
            }

        case .shareReaderArticle, .actionReaderArticle:
            // The share/action extension article reader, hosted in-app (the real
            // share sheet can't be driven on a simulator). URL is provably valid.
            guard let url = URL(string: "https://example.com/article") else {
                return UINavigationController(rootViewController: ReadingListViewController())
            }
            let reader = ShareReaderViewController(url: url, mode: .reader, onDone: {})
            return UINavigationController(rootViewController: reader)

        case .shareMediaPlatform:
            let screen = SavedNonTextualViewController(
                articleURLString: "https://x.com/user/status/123",
                content: .platform(.x, itemID: "123"), onDone: {})
            return UINavigationController(rootViewController: screen)

        case .catchUp:
            // Catch-up is presented modally over the reading list. Host the list and
            // present the card stack once it's on screen.
            let router = ReadingListViewController()
            let host = UINavigationController(rootViewController: router)
            return PresentingHostViewController(host: host) { [weak router] in
                guard let router else { return nil }
                let queue = ReadingListSectioning.catchUpQueue(items: ReadingListStore.shared.items())
                guard !queue.isEmpty else { return nil }
                return CatchUpViewController(unread: queue, router: router)
            }
        }
    }

    private static func reader(forceMode: ReadingListItem.ReaderMode) -> ReaderViewController {
        ReaderViewController(item: fixtureItem, content: fixtureContent, forceMode: forceMode,
                             persistsModePreference: false, marksOpenedOnLoad: false)
    }
}

/// A container that shows `host` and, once it has appeared, presents a modal built
/// by `makeModal`. Used to deep-link to screens (e.g. the catch-up card stack) that
/// the app only ever shows modally over the reading list. DEBUG-only test scaffolding.
final class PresentingHostViewController: UIViewController {
    private let host: UIViewController
    private let makeModal: () -> UIViewController?
    private var hasPresented = false

    init(host: UIViewController, makeModal: @escaping () -> UIViewController?) {
        self.host = host
        self.makeModal = makeModal
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasPresented, let modal = makeModal() else { return }
        hasPresented = true
        if modal.modalPresentationStyle == .automatic {
            modal.modalPresentationStyle = .fullScreen
        }
        present(modal, animated: modal is SplitWebOverlayViewController)
    }
}
#endif
