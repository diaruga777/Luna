//
//  KindWiring+Reader.swift
//  Luna
//
//  Per-app composition root. It registers the per-kind processors, ingestor
//  handlers, and UI/lifecycle seams this app's target links. Each app target
//  compiles exactly one `KindWiring` variant — the synchronized group excludes
//  the others by membership exception — so the registries and the static
//  lifecycle API below mirror this app's own link set.
//

import LunaDesignSystem
import LunaIngest
import LunaMailAccount
import LunaModels
import LunaReaderUI
import LunaSaves
import LunaSend
import LunaStorage
import UIKit

enum KindWiring {
    private static var xteinkRendezvousObserver: NSObjectProtocol?
    /// Migration only — onboarding stores nothing (see
    /// `OnboardingLegacyDemoSweeping`).
    private static let legacyOnboardingDemoSave: any OnboardingLegacyDemoSweeping =
        BundledLunaArticle.LegacySweep()

    /// Only registrations needed to construct the saved-card hierarchy.
    @MainActor
    static func installPresentation() {
        #if DEBUG
        AppOnboardingStore.shared.resetIfRequested()
        // Staged mode's catalogs, for this app's kinds only
        // (`claudedocs/staging.md`).
        SharedStageCatalog.install()
        ArticleStageCatalog.install()
        EmailStageCatalog.install()
        #endif
        ArticleKindComposition.install()
        CardKindPresenters.article = ArticleCardPresenter()
        ArticleShellWiring.installPresentation()
    }

    @MainActor
    static func install() {
        // The Luna file intake seam. Every root installs a witness, so a
        // `.luna` file reaching a surface is always accounted for; the
        // recovery and plugin surfaces replace it with their own.
        LunaFileIntake.recoveryHandler = RecoveryFileIntake()
        LunaFileIntake.pluginHandler = UnsupportedLunaFileIntake()

        // The article kind's app-shell half installs from the same file the
        // central app uses (`ArticleShellWiring`).
        ArticleShellWiring.install()
    }

    // MARK: - Root UI shape

    /// The article card deck, wrapped in the window-level audio mini-player
    /// host. Read-aloud is a Reader feature; the bar floats above the bottom
    /// safe area, survives every push and pop, and hides while idle.
    static func makeRootViewController() -> UIViewController {
        let content: UIViewController = ArticleCardsViewController()
        let nav = UINavigationController(rootViewController: content)
        return MiniPlayerHostViewController(content: nav)
    }

    static func mainNavigationController(of root: UIViewController) -> UINavigationController? {
        if let host = root as? MiniPlayerHostViewController {
            return host.contentNavigationController
        }
        return root as? UINavigationController
    }

    static func openPriceTrackerAddSeller(
        itemID: UUID, navigationController: UINavigationController
    ) {}

    static func settingsCategories() -> [SettingsCategory] {
        [
            SettingsCategory(title: L10n.string("Common_reader"), symbol: "textformat.size") { ReaderSettingsScreen() },
            SettingsCategory(title: L10n.string("Common_audio"), symbol: "headphones") { AudioSettingsScreen() },
            SettingsCategory(
                title: L10n.string("Common_email"),
                symbol: "envelope",
                detail: {
                    EmailAccountStore.shared.authenticationIssue == nil
                        ? nil : L10n.string("Common_signInRequired")
                }
            ) { EmailAndKindleSettingsScreen() },
            SettingsCategory(
                title: L10n.string("Common_kindle"), symbol: "book.closed",
                requiresEmail: true,
                makePrerequisite: {
                    let email = EmailAndKindleSettingsScreen()
                    email.focusesAddressField = true
                    return email
                }
            ) {
                KindleSettingsScreen()
            },
            SettingsCategory(
                title: L10n.string("Common_xteink"), symbol: "books.vertical",
                detail: {
                    XteinkSendSettings.isEnabled ? nil : L10n.string("Common_off")
                }
            ) { XteinkSettingsScreen() },
        ]
    }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    static func appDidLaunch() {
        legacyOnboardingDemoSave.sweepLegacyDemoSave()
        ArticleShellWiring.appDidLaunch()
        // The X3 advertises briefly after a power-button wake. Keep the central
        // eligible for state restoration; it does no network work until that
        // rendezvous actually appears.
        XteinkBLECentral.shared.beginRendezvousScan()
        if xteinkRendezvousObserver == nil {
            xteinkRendezvousObserver = NotificationCenter.default.addObserver(
                forName: .xteinkRendezvousReady, object: nil, queue: .main
            ) { _ in
                // A restored central can become ready long after launch's first
                // sweep. This is the actual transfer trigger for a wake window.
                XteinkRendezvousSweepPolicy.rendezvousBecameReady(
                    isReadReportOnlyWindow: XteinkBLECentral.shared.isReadReportOnlyWindow,
                    acquireSweepLock: { XteinkRendezvousSweepLock.shared.acquire() },
                    releaseSweepLock: { XteinkRendezvousSweepLock.shared.release() },
                    drainPendingDeletes: { await XteinkRemoteDeleteRunner.drainPendingDeletes() },
                    deliverQueuedSends: {
                        await ArticleSendCoordinator.shared.deliverQueuedSends(
                            toDestinationID: ArticleDestinationID.xteink)
                    },
                    reportNoWork: {
                        // Behind the transfer queue so a straggler send (an
                        // auto-send landing mid-window) finishes first.
                        try await XteinkRendezvousTransferQueue.shared.run {
                            try await XteinkBLECentral.shared.reportNoWork()
                        }
                    })
            }
        }
    }

    static func appDidEnterBackground() {
        ArticleShellWiring.appDidEnterBackground()
    }

    static func sceneDidForeground() {
        ArticleShellWiring.sceneDidForeground()
        XteinkBLECentral.shared.beginRendezvousScan()
    }

    static func savesDidChange() {}

    static func wifiBecameAvailable() {
        ArticleShellWiring.resumeIncompletePreloads()
        // The Xteink receives over local Wi-Fi, so joining a network is a
        // delivery opportunity for queued ereader sends.
        ArticleShellWiring.retryPendingSends()
    }

    static func retryPendingArticleSends() {
        ArticleShellWiring.retryPendingSends()
    }

    static func attachBackgroundURLSessionHandler(
        identifier: String, _ completionHandler: @escaping () -> Void
    ) {
        // Reader links no media kind, so there is no background URLSession
        // to reattach. It completes the callback immediately so the system
        // isn't left waiting.
        completionHandler()
    }

    /// Reader links no media module, so it has no Live Activity and this
    /// route never actually fires. `SceneDelegate` is universal, so the
    /// method must still exist.
    static func mediaDeepLinkAction(forURLString urlString: String) -> MediaDeepLinkAction { .none }

    /// Reader produces no downloaded file, so it has nothing to share.
    static let mediaShareFileExporter: (any MediaShareFileExporting)? = nil

    /// Reader's Safari extension resolves no video (the native handler gates
    /// on `hostHandlesMedia`), so nothing can ever queue a download for it.
    static func drainPendingResolvedMedia(returningToSource: Bool) {}

    /// Central Luna only (`claudedocs/plans/plugin-platform.md` §2.1); Reader
    /// runs no plugin platform, so its own queue can never hold anything.
    static func drainPendingPluginModels(returningToSource: Bool) {}

    /// Central Luna only; Reader's Safari extension never creates this handoff.
    static func openPendingPluginRecoveryCase(caseID: UUID) {}

    /// The extension's LLM hand-off, arriving as `<scheme>://llm?item=…` when
    /// the extension's own open was refused.
    @MainActor
    static func openLLMHandoff(itemID: UUID) {
        LLMHandoffResume.open(itemID: itemID)
    }

    /// Reader handles no products, so there is no runner. AppDelegate never
    /// registers or schedules the price-refresh BGTask.
    static let priceRefreshRunner: (any PriceRefreshRunning)? = nil

    #if DEBUG
    /// `-openArchive <url>` debug root: the interactive archive reader.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? {
        ArticleShellWiring.debugArchiveReaderRoot(articleURL: articleURL)
    }
    #endif
}
