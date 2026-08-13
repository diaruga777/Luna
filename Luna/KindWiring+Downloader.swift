//
//  KindWiring+Downloader.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors,
//  ingestor handlers, and UI/lifecycle seams this app's target links. EXACTLY
//  ONE KindWiring variant is compiled into each app target (the other variants
//  are excluded via the synchronized group's per-target membership exceptions)
//  — the registries and the static lifecycle API below mirror the link set.
//

import LunaMediaDownload
import LunaModels
import LunaReadingList
import LunaStorage
import UIKit

enum KindWiring {
    /// Migration only — onboarding stores nothing (see `OnboardingLegacyDemoSave`).
    private static let legacyOnboardingDemoSave =
        DownloaderOnboardingDemoSave.legacyCleanup

    @MainActor
    static func install() {
        #if DEBUG
        AppOnboardingStore.shared.resetIfRequested()
        // Staged mode's catalogs — this app's kinds only (`claudedocs/staging.md`).
        SharedStageCatalog.install()
        MediaStageCatalog.install()
        #endif

        // The media kind pack — one call, shared verbatim with the Downloader's
        // share and action extensions (`MediaKindComposition`). Media needs no
        // web-processing pipeline stage (platform recognition is URL-only
        // classification), which is stated there rather than re-derived here.
        MediaKindComposition.install()
        // The media kind's CARD half, on the same principle — the one
        // definition the central app installs too (`CardKindPresenter.swift`).
        CardKindPresenters.media = MediaCardPresenter()
        // …and the media kind's half of the app shell, which the central app
        // installs from the same file (`MediaShellWiring`).
        MediaShellWiring.install()
    }

    // MARK: - Root UI shape

    /// The saved-media card deck in a bare nav controller — no audio
    /// mini-player host (read-aloud is an article-app feature). The deck itself
    /// is the shared host configured by `MediaCardDeck`; this app has no deck
    /// subclass of its own.
    @MainActor
    static func makeRootViewController() -> UIViewController {
        UINavigationController(rootViewController: MediaCardDeck.makeRoot())
    }

    static func mainNavigationController(of root: UIViewController) -> UINavigationController? {
        root as? UINavigationController
    }

    static func openPriceTrackerAddSeller(
        itemID: UUID, navigationController: UINavigationController
    ) {}

    static func settingsCategories() -> [SettingsCategory] {
        [
            SettingsCategory(title: L10n.string("Common_downloads"), symbol: "arrow.down.circle") {
                DownloadsSettingsScreen()
            },
        ]
    }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    static func drainPendingResolvedMedia(returningToSource: Bool) {
        MediaShellWiring.drainPendingResolvedMedia(returningToSource: returningToSource)
    }

    static func appDidLaunch() {
        legacyOnboardingDemoSave.cleanup()
        MediaShellWiring.appDidLaunch()
    }

    static func appDidEnterBackground() {
        MediaShellWiring.appDidEnterBackground()
    }

    static func sceneDidForeground() {
        MediaShellWiring.sceneDidForeground()
        // Foregrounding is possibly the first time this process is on Wi-Fi
        // since a download queued, so it resumes what the policy deferred —
        // the central app leaves that to the reachability notification.
        MediaShellWiring.resumePendingWiFiDownloads()
    }

    static func readingListDidChange() {
        MediaShellWiring.readingListDidChange()
    }

    static func wifiBecameAvailable() {
        MediaShellWiring.resumePendingWiFiDownloads()
    }

    /// Downloader handles no articles — ereader sends are never pending here.
    static func retryPendingArticleSends() {}

    static func attachBackgroundURLSessionHandler(_ completionHandler: @escaping () -> Void) {
        MediaShellWiring.attachBackgroundURLSessionHandler(completionHandler)
    }

    static func mediaDeepLinkAction(forURLString urlString: String) -> MediaDeepLinkAction {
        MediaShellWiring.deepLinkAction(forURLString: urlString)
    }

    static let mediaShareFileExporter: MediaShareFileExporting? =
        MediaShellWiring.shareFileExporter

    /// Downloader handles no products — no runner ⇒ AppDelegate never registers
    /// or schedules the price-refresh BGTask.
    static let priceRefreshRunner: (() async -> Int)? = nil

    #if DEBUG
    /// `-openArchive` is an article-app debug tool.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? { nil }
    #endif
}
