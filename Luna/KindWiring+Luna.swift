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
import LunaPluginExport
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
        installFullPluginComposition()
        PluginModelDrain.returnOpener = SystemPluginModelReturnOpener()
        // A destination plugin's "Auto-send" row opens the app shell's
        // per-capture-source screen, which LunaPluginUI cannot see.
        PluginDestinationAutoSend.presenter = PluginAutoSendRoute()
        // The double save's Kindle setup step, replaced after
        // `ArticleShellWiring.install`. Kindle is a PLUGIN here, and the Swift
        // screen writes `KindleSendSettings.kindleAddress`, which reaches the
        // plugin only at the next launch's migration — so an address typed
        // there left the destination unconfigured for the rest of the session.
        DoubleSaveSettingsSupport.kindleSetupLauncher = PluginKindleSetupRoute()
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

    /// The plugin platform's full composition for this app: the runtime plus
    /// every bridge tier `Luna` links (UI, transport, export) and the two
    /// app-only witnesses that ride on top of it. `install()` calls this once
    /// at launch; `PluginPlatformBootTests.tearDown` calls it again after a
    /// test installs a bare platform of its own, so the suites that run after
    /// it find the shipped composition rather than one missing `luna.ui`,
    /// `luna.browser`, `luna.settings` and every export/transport bridge.
    @MainActor
    static func installFullPluginComposition() {
        PluginPlatformComposition.install(
            processKind: .app,
            bundledPluginsBundle: LunaBundledPluginsBundle.bundle,
            additionalBridges: {
                PluginUIComposition.bridges(processKind: .app, scheduler: $0)
                    + PluginTransportComposition.bridges(processKind: .app, scheduler: $0)
                    + PluginExportComposition.bridges(processKind: .app, scheduler: $0)
            })
        PluginUIComposition.installAppWitnesses()
        // The export tier reads the runtime the call above built, so it comes
        // after it. It also retires the Swift destinations its plugins take
        // over — `KindleDestination` is the Kindle plugin's now.
        PluginExportComposition.install(
            mediaFiles: PluginMediaFileLocator(),
            recipientPicker: PluginMailRecipientPrompt())
    }

    /// The Kindle plugin's own settings screen, where its address lives.
    /// With no listing the plugin is not loaded, so the Swift destination is
    /// still the live one and its screen is the right answer.
    private struct PluginKindleSetupRoute: KindleSetupPresenting {
        @MainActor
        func presentKindleSetup(from presenter: UIViewController) {
            guard EmailAccountStore.shared.isConfigured else {
                EmailAndKindleSettingsScreen.pushForAccountSetup(from: presenter)
                return
            }
            guard let catalog = PluginPlatformServices.catalog,
                  let listing = catalog.listing(pluginID: KindlePlugin.pluginID)
            else {
                presenter.navigationController?.pushViewController(
                    KindleSettingsScreen(), animated: true)
                return
            }
            presenter.navigationController?.pushViewController(
                PluginDetailScreen(
                    listing: listing, catalog: catalog,
                    settingsStore: PluginPlatformServices.settings ?? NullPluginSettingsStore(),
                    invoker: PluginPlatformServices.invoker),
                animated: true)
        }
    }

    /// The per-capture-source auto-send screen for a destination plugin.
    private struct PluginAutoSendRoute: PluginDestinationAutoSendPresenting {
        @MainActor
        func presentAutoSend(
            destinationID: String, displayName: String, from presenter: UIViewController
        ) {
            presenter.navigationController?.pushViewController(
                AutoSendBySourceScreen(
                    destinationID: destinationID, destinationName: displayName),
                animated: true)
        }
    }

    /// Where a media save's downloaded file is, for a plugin exporting one.
    /// This app is the only place that sees both the export tier and the media
    /// module.
    private final class PluginMediaFileLocator: PluginExportMediaFileLocating {
        func mediaFileURL(forSaveID saveID: UUID) -> URL? {
            SavedMediaStore.shared.item(withID: saveID)?.fileURL
        }
    }

    /// `luna.mail`'s recipient picker, for a plugin message that named none.
    ///
    /// The picker reports only a SEND. A cancel just dismisses it, so the
    /// dismissal is what reports the cancel — otherwise the plugin's promise
    /// would never settle.
    private final class PluginMailRecipientPrompt: PluginMailRecipientPicking {
        @MainActor
        func pickMailRecipients(subject: String) async -> [String]? {
            guard let presenter = PluginExportTopPresenter.current() else { return nil }
            let answered = OneAnswer()
            return await withCheckedContinuation { continuation in
                let picker = RecipientPickerViewController { emails in
                    guard answered.claim() else { return }
                    continuation.resume(returning: emails.isEmpty ? nil : emails)
                }
                let navigation = UINavigationController(rootViewController: picker)
                presenter.present(navigation, animated: true)
                Task { @MainActor in
                    while navigation.presentingViewController != nil {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                    guard answered.claim() else { return }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Lets exactly one of two racing paths resume a continuation.
    @MainActor
    private final class OneAnswer {
        private var taken = false
        func claim() -> Bool {
            guard !taken else { return false }
            taken = true
            return true
        }
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
