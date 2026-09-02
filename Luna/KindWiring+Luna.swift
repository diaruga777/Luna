//
//  KindWiring+Luna.swift
//  Luna
//
//  Per-app composition root. It registers the per-kind processors, ingestor
//  handlers, and UI/lifecycle seams this app's target links. Each app target
//  compiles exactly one `KindWiring` variant — the synchronized group excludes
//  the others by membership exception — so the registries and the static
//  lifecycle API below mirror this app's own link set.
//

import LunaBundledPlugins
import LunaIngest
import LunaMailAccount
import LunaMediaDownload
import LunaPluginIngest
import LunaPluginTransport
import LunaPluginUI
import LunaPluginKit
import LunaModels
import LunaPriceUI
import LunaReaderUI
import LunaSaves
import LunaSend
import LunaSocialUI
import LunaStorage
import UIKit

enum KindWiring {
    /// Migration only — onboarding stores nothing (see
    /// `OnboardingLegacyDemoSweeping`).
    private static let legacyOnboardingDemoSave: any OnboardingLegacyDemoSweeping =
        BundledLunaArticle.LegacySweep()

    @MainActor
    static func install() {
        #if DEBUG
        AppOnboardingStore.shared.resetIfRequested()
        // Staged mode's catalogs follow the same rule as the kind packs: a
        // kind's stages live with that kind, and this app installs the ones
        // for the kinds it links (`claudedocs/staging.md`). This is a no-op
        // unless the app launches with `-LunaStage`.
        SharedStageCatalog.install()
        ArticleStageCatalog.install()
        EmailStageCatalog.install()
        MediaStageCatalog.install()
        ProductStageCatalog.install()
        PluginStageCatalog.install()
        #endif

        // One install call per kind this app handles. What each kind
        // registers is defined once in that kind's own module and shared by
        // every surface — app, share extension, action extension, clip. See
        // `ArticleKindComposition`.
        ArticleKindComposition.install()
        MediaKindComposition.install()
        ProductKindComposition.install()
        PluginPlatformComposition.install(
            processKind: .app,
            bundledPluginsBundle: LunaBundledPluginsBundle.bundle,
            additionalBridges: {
                PluginUIComposition.bridges(processKind: .app, scheduler: $0)
                    + PluginTransportComposition.bridges(processKind: .app, scheduler: $0)
            })
        PluginUIComposition.installAppWitnesses()
        // The card half of each kind follows the same rule: one definition
        // per kind, installed by every app that shows it, so the central deck
        // and each single-kind deck can't disagree about the same save. See
        // `CardKindPresenter.swift`.
        CardKindPresenters.article = ArticleCardPresenter()
        CardKindPresenters.media = MediaCardPresenter()
        CardKindPresenters.product = ProductCardPresenter()
        // The app-shell half of each kind installs from the same files each
        // single-kind app uses (`ArticleShellWiring` and its siblings), so the
        // central app can't drift from the app that specializes in that kind.
        ArticleShellWiring.install()
        MediaShellWiring.install()
        ProductShellWiring.install()
        // A Luna email carrying a price tracker shows its graph as an image —
        // the one seam that needs an article-app capability (email) and a
        // product-app one (the graph) at once, so it belongs to neither leg.
        EmailShareCenter.priceGraphSnapshot = TrackerEmailGraphRenderer()
    }

    /// The tracker email's hero image, drawn by the product module's snapshot
    /// renderer.
    private struct TrackerEmailGraphRenderer: PriceGraphEmailRendering {
        @MainActor
        func jpegData(for tracker: PriceTracker) -> Data? {
            PriceGraphEmailSnapshot.jpegData(for: tracker)
        }
    }

    // MARK: - Root UI shape

    /// The all-kinds card deck, wrapped in the window-level audio mini-player
    /// host. Read-aloud is an article-app feature; the bar floats above the
    /// bottom safe area, survives every push and pop, and hides while idle.
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

    @MainActor
    static func openPriceTrackerAddSeller(
        itemID: UUID, navigationController: UINavigationController
    ) {
        ProductShellWiring.openAddSeller(
            itemID: itemID, navigationController: navigationController)
    }

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
            SettingsCategory(title: L10n.string("Common_downloads"), symbol: "play.fill") {
                DownloadsSettingsScreen()
            },
            PluginsSettingsCategory.make(),
        ]
    }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    static func drainPendingResolvedMedia(returningToSource: Bool) {
        MediaShellWiring.drainPendingResolvedMedia(returningToSource: returningToSource)
    }

    /// Drains what the Safari content script queued through
    /// `plugins.queueModel` (`claudedocs/plans/plugin-platform.md` §13.1).
    static func drainPendingPluginModels(returningToSource: Bool) {
        PluginModelDrain.run(
            returningToSource: returningToSource,
            productInfoBuilder: PluginProductInfoBuilder.make(from:imageURL:))
    }

    static func appDidLaunch() {
        legacyOnboardingDemoSave.sweepLegacyDemoSave()
        ArticleShellWiring.appDidLaunch()
        MediaShellWiring.appDidLaunch()
        Task { @MainActor in PluginUnlockFlow.resumeCompleted() }
        ProductShellWiring.appDidLaunch()
        // Xteink is a bundled PLUGIN in this app: `xteink.js` owns the
        // rendezvous sweep, the transfer and the settings screen, and its
        // `luna.bluetooth` center opens the standing connect a short wake
        // window needs. Luna Reader keeps the Swift path (`KindWiring+Reader`)
        // and the two exclude each other through the service lock.
        PluginTransportComposition.install()
        PluginTransportComposition.appDidLaunch()
    }

    static func appDidEnterBackground() {
        ArticleShellWiring.appDidEnterBackground()
        MediaShellWiring.appDidEnterBackground()
        ProductShellWiring.appDidEnterBackground()
    }

    static func sceneDidForeground() {
        MediaShellWiring.sceneDidForeground()
        Task { @MainActor in PluginUnlockFlow.resumeCompleted() }
        ArticleShellWiring.sceneDidForeground()
        drainPendingPluginModels(returningToSource: false)
        PluginTransportComposition.sceneDidForeground()
    }

    static func savesDidChange() {
        MediaShellWiring.savesDidChange()
    }

    static func wifiBecameAvailable() {
        MediaShellWiring.resumePendingWiFiDownloads()
        ArticleShellWiring.resumeIncompletePreloads()
        // An ereader receives over local Wi-Fi, so joining a network is a
        // delivery opportunity for queued sends.
        ArticleShellWiring.retryPendingSends()
    }

    static func retryPendingArticleSends() {
        ArticleShellWiring.retryPendingSends()
    }

    static func attachBackgroundURLSessionHandler(
        identifier: String, _ completionHandler: @escaping () -> Void
    ) {
        MediaShellWiring.attachBackgroundURLSessionHandler(identifier: identifier, completionHandler)
    }

    static func mediaDeepLinkAction(forURLString urlString: String) -> MediaDeepLinkAction {
        MediaShellWiring.deepLinkAction(forURLString: urlString)
    }

    static let mediaShareFileExporter: (any MediaShareFileExporting)? =
        MediaShellWiring.shareFileExporter

    /// Runs one price-refresh pass and returns the processed-tracker count.
    /// Non-nil only in product-handling apps; its presence is what arms the
    /// price-refresh BGTask registration/scheduling in AppDelegate.
    static let priceRefreshRunner: (any PriceRefreshRunning)? =
        ProductShellWiring.priceRefreshRunner

    #if DEBUG
    /// `-openArchive <url>` debug root: the interactive archive reader.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? {
        ArticleShellWiring.debugArchiveReaderRoot(articleURL: articleURL)
    }
    #endif
}
