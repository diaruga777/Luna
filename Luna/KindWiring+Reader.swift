//
//  KindWiring+Reader.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors,
//  ingestor handlers, and UI/lifecycle seams this app's target links. EXACTLY
//  ONE KindWiring variant is compiled into each app target (the other variants
//  are excluded via the synchronized group's per-target membership exceptions)
//  — the registries and the static lifecycle API below mirror the link set.
//

import LunaDesignSystem
import LunaIngest
import LunaMailAccount
import LunaModels
import LunaReaderUI
import LunaReadingList
import LunaSend
import LunaStorage
import UIKit

enum KindWiring {
    /// Migration only — onboarding stores nothing (see `OnboardingLegacyDemoSave`).
    private static let legacyOnboardingDemoSave = OnboardingLegacyDemoSave(
        cleanup: { BundledLunaArticle.cleanupLegacyTemporarySave() })

    @MainActor
    static func install() {
        #if DEBUG
        AppOnboardingStore.shared.resetIfRequested()
        // Staged mode's catalogs — this app's kinds only (`claudedocs/staging.md`).
        SharedStageCatalog.install()
        ArticleStageCatalog.install()
        EmailStageCatalog.install()
        #endif

        // The article kind pack — one call, shared verbatim with Reader's share
        // extension, action extension and App Clip (`ArticleKindComposition`).
        ArticleKindComposition.install()
        // The article kind's CARD half, on the same principle — the one
        // definition the central app installs too (`CardKindPresenter.swift`).
        CardKindPresenters.article = ArticleCardPresenter()
        // …and the article kind's half of the app shell, which the central app
        // installs from the same file (`ArticleShellWiring`).
        ArticleShellWiring.install()
    }

    // MARK: - Root UI shape

    /// The article card deck, wrapped in the window-level audio mini-player
    /// host (read-aloud is a Reader feature; the bar floats above the bottom
    /// safe area, survives every push/pop, and hides while idle).
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
        ]
    }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    static func appDidLaunch() {
        legacyOnboardingDemoSave.cleanup()
        ArticleShellWiring.appDidLaunch()
    }

    static func appDidEnterBackground() {
        ArticleShellWiring.appDidEnterBackground()
    }

    static func sceneDidForeground() {
        ArticleShellWiring.sceneDidForeground()
    }

    static func readingListDidChange() {}

    static func wifiBecameAvailable() {
        ArticleShellWiring.resumeIncompletePreloads()
    }

    static func retryPendingArticleSends() {
        ArticleShellWiring.retryPendingSends()
    }

    static func attachBackgroundURLSessionHandler(_ completionHandler: @escaping () -> Void) {
        // No media kind → no background URLSession to reattach; complete the
        // callback immediately so the system isn't left waiting.
        completionHandler()
    }

    /// Reader links no media module — no Live Activity, so this route never
    /// actually fires here, but `SceneDelegate` is universal.
    static func mediaDeepLinkAction(forURLString urlString: String) -> MediaDeepLinkAction { .none }

    /// …and so nothing here can produce a downloaded file to share either.
    static let mediaShareFileExporter: (any MediaShareFileExporting)? = nil

    /// Reader's Safari extension resolves no video (the native handler gates on
    /// `hostHandlesMedia`), so nothing can ever queue a download for it.
    static func drainPendingResolvedMedia(returningToSource: Bool) {}

    /// Reader handles no products — no runner ⇒ AppDelegate never registers or
    /// schedules the price-refresh BGTask.
    static let priceRefreshRunner: (() async -> Int)? = nil

    #if DEBUG
    /// `-openArchive <url>` debug root: the interactive archive reader.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? {
        ArticleShellWiring.debugArchiveReaderRoot(articleURL: articleURL)
    }
    #endif
}
