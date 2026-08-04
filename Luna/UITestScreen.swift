//
//  UITestScreen.swift
//  Luna
//

import LunaReadingListUI
import LunaMailAccount
import LunaSocialUI
import LunaShareSurface
import LunaMediaDownload
import LunaPriceUI
import LunaReaderUI
import LunaStorage
import LunaModels
import LunaURLClassification
import UIKit

#if DEBUG
/// A named screen the screenshot harness can deep-link to on launch via
/// `-uiTestScreen <rawValue>`. Coordinate-tapping is fragile across the many
/// device sizes the screenshot agent captures, so instead of navigating the UI
/// the agent asks the app to build the target screen directly as (or presented
/// over) the window's root.
///
/// Every case maps to the exact construction seam the unit tests use
/// (`ReaderViewController(item:content:…)`, `ShareReaderViewController(url:mode:onDone:)`,
/// etc.), so a deep-linked screen renders the same content the snapshot tests assert on.
///
/// DEBUG-only and launch-arg-gated — production code paths never reference this.
/// See `claudedocs/ui-testing.md`.
enum UITestScreen: String, CaseIterable {
    // Reading list is reachable via `-uiTestState` alone, but these let the agent
    // request specific list-driven modals/pushes deterministically.
    case friends
    case friendDetail
    case settings
    case emailRecovery
    case priceTrackingEditor
    case importExport
    /// The import review sheet, over Import & Export, with a fixture document —
    /// the real one only ever arrives from a file the document picker returned.
    case importReview

    // Readers (built from a deterministic fixture article).
    case readerScroll
    case readerHighlight
    case readerRSVP
    case readerOriginal
    case readerInlineHeader
    case readerNested

    // Reader-adjacent extension/host screens.
    case shareReaderArticle
    case shareMediaPlatform
    case actionReaderArticle
    case actionMediaPlatform
    case actionRescueFailure
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

    /// A both-sections document for the import review sheet.
    private static var importReviewFixture: LinkListDocument {
        LinkListDocument(
            links: [
                "https://example.com/the-quiet-architecture-of-everyday-things",
                "https://example.com/notes-on-a-long-winter",
                "https://example.org/why-maps-lie",
            ],
            archived: ["https://example.com/an-older-piece-worth-keeping"],
            isStructured: true)
    }

    /// Returns the root view controller for `screen`. The store has already been
    /// seeded by `UITestSeeder.applyIfNeeded()` before this is called.
    static func rootViewController(for screen: UITestScreen) -> UIViewController {
        switch screen {
        case .settings:
            return UINavigationController(rootViewController: SettingsViewController())

        case .importExport:
            return UINavigationController(rootViewController: ImportExportSettingsScreen())

        case .importReview:
            let host = UINavigationController(rootViewController: ImportExportSettingsScreen())
            return PresentingHostViewController(host: host) {
                LinkImportSheetViewController(document: importReviewFixture)
            }

        case .emailRecovery:
            let suiteName = "UITestScreen.emailRecovery"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            let store = EmailAccountStore(
                defaults: defaults, credentialStorage: InMemoryCredentialStorage())
            store.save(
                EmailAccount(providerID: .gmail, address: "reader@example.com"),
                credential: .appPassword("fixture-password"))
            store.markAuthenticationIssue(.credentialsRejected)
            return UINavigationController(
                rootViewController: EmailAndKindleSettingsScreen(accountStore: store))

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
            return KindWiring.makeRootViewController()

        case .readerScroll:
            return UINavigationController(rootViewController: reader(forceMode: .scroll))
        case .readerHighlight:
            return UINavigationController(rootViewController: reader(forceMode: .highlight))
        case .readerRSVP:
            return UINavigationController(rootViewController: reader(forceMode: .rsvp))
        case .readerOriginal:
            let store = ReadingListStore.shared
            guard let item = store.items().first(where: {
                $0.state == .ready && $0.canHaveOriginalArchive
            }), let content = store.content(for: item) else {
                return KindWiring.makeRootViewController()
            }
            let reader = ReaderViewController(
                item: item, content: content, forceMode: .original,
                persistsModePreference: false, marksOpenedOnLoad: false)
            return UINavigationController(rootViewController: reader)
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
                nested.presentationCoordinator = reader
                return nested
            }

        case .shareReaderArticle, .actionReaderArticle:
            // The share/action extension article reader, hosted in-app (the real
            // share sheet can't be driven on a simulator). URL is provably valid.
            guard let url = URL(string: "https://example.com/article") else {
                return KindWiring.makeRootViewController()
            }
            let reader = ShareReaderViewController(url: url, mode: .reader, onDone: {})
            return UINavigationController(rootViewController: reader)

        case .shareMediaPlatform, .actionMediaPlatform:
            // The same screen either way, minus the system-share circle in the
            // share extension (its user just came from a share sheet).
            let screen = SavedNonTextualViewController(
                articleURLString: "https://x.com/user/status/123",
                showsSystemShare: screen == .actionMediaPlatform, onDone: {})
            return UINavigationController(rootViewController: screen)

        case .actionRescueFailure:
            // The extension's failure card, hosted in-app — the real share sheet
            // can't be driven on a simulator, and this card is the one extension
            // screen whose layout is worth checking (it mirrors the in-app failed
            // card, so the two must be comparable side by side).
            guard let url = URL(string: "https://example.com/broken") else {
                return KindWiring.makeRootViewController()
            }
            let card = RescueFailureViewController(
                url: url, rescueURL: URL(string: "luna://rescue"),
                openApp: { _ in }, onFinish: {}, onDone: {})
            return UINavigationController(rootViewController: card)

        }
    }

    private static func reader(forceMode: ReadingListItem.ReaderMode) -> ReaderViewController {
        ReaderViewController(item: fixtureItem, content: fixtureContent, forceMode: forceMode,
                             persistsModePreference: false, marksOpenedOnLoad: false)
    }
}

/// A container that shows `host` and, once it has appeared, presents a modal built
/// by `makeModal`. Used to deep-link to screens the app only ever shows modally over
/// another root (e.g. the nested split-web overlay). DEBUG-only test scaffolding.
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
