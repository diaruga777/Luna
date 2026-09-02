//
//  ArticleShellWiring.swift
//  Luna
//
//  The article kind's half of the app shell. It installs every seam an
//  article-handling app needs at launch, and does the lifecycle work
//  articles owe at each of `KindWiring`'s fixed points. Only the targets that
//  link the article kind compile this file — Luna and LunaReader. The other
//  two exclude it by membership exception, the same way they exclude
//  `Reader/ArticleCardPresenter.swift` and the rest of the article shell.
//
//  A `KindWiring+<App>` variant installs the article kind pack
//  (`ArticleKindComposition`) and the article card presenter itself, then
//  calls the legs below. Nothing article-specific is written twice.
//

import LunaArchiveReader
import LunaArticleIngest
import LunaAudioPlayback
import LunaIngest
import LunaMailAccount
import LunaMailTransport
import LunaModels
import LunaReaderUI
import LunaSaves
import LunaSend
import LunaSocialUI
import LunaStorage
import UIKit

enum ArticleShellWiring {

    @MainActor
    static func install() {
        IngestorKindHandlers.article = ArticleKindHandler()

        // A completion written before a force-quit never received the normal
        // background callback. Promote it before constructing the Reader UI.
        SavesStore.shared.archivePendingFinishedItems()

        // Send-to-Kindle emails go out through the connected email account.
        // LunaSend sits below LunaMailTransport, so the transport factory is
        // injected here. An extension leaves it nil, so Kindle sends are
        // no-ops there.
        ArticleEmailTransportProvider.installed = MailFactoryTransportProvider()

        // Installs the autoplay queue provider and registers the Now
        // Playing / remote-command coordinator (`claudedocs/audio-playback
        // -plan.md`, Phase 2). Registration must happen at launch, not
        // lazily, so a cold background relaunch from a lock-screen play
        // command can restore the persisted session. Read-aloud — the
        // app-wide center, its background session, the window mini-player —
        // belongs exclusively to article-handling apps. The Downloader and
        // Price Tracker leave `ReaderAudioLauncher.center` nil, which keeps
        // their shared readers on the legacy self-contained
        // `SpeechController` path.
        AudioPlaybackWiring.install()
        // The trimming pipeline's opportunistic script-cache builder (Phase
        // 4). It is wired right after playback, so its scriptProvider and
        // scriptPrefetchHandler seams are set before anything can call into
        // the center.
        AudioScriptPipelineWiring.install()

        // The Action Button double save (`claudedocs/double-save.md`). Its
        // "View immediately" returns an article document, and Kindle needs
        // the account/Kindle setup screens. Both are article-only, so both
        // install here, matching `ActionButtonIntentSupport
        // .doubleSaveSurface`, which arms double save in exactly the apps
        // that link LunaSend.
        ActionButtonIntentSupport.articleExport = ArticleIntentExporter()
        // Exports fetch article images that haven't landed yet, rather than
        // shipping a file with none. The downloader lives in LunaReaderUI
        // and the exporters live in LunaSend, so the composition root joins
        // them.
        ArticleExportImages.preparer = ArticleExportImageDownloader()
        DoubleSaveSettingsSupport.kindleSetupLauncher = KindleSetupPresenter()

        // A bulk import's pass over saves that came back hard-paywalled: the
        // same web unlock a tap would run, off-screen, giving up on any
        // CAPTCHA (`claudedocs/import-export.md`). Article apps only — there
        // is no article save to unlock anywhere else.
        LinkImportRunner.articleUnlocker = ImportArticleUnlocker()

        // Voice status and installation live on the Audio settings page.
        VoiceFirstRunPrompt.voiceSettings = AudioSettingsRoute()

        // Sending needs a connected email account. An attempted send without
        // one redirects to the screen that connects it — its Sharing Account
        // section is the sign-in form until then. Only the email-sending
        // apps compile that screen, and they are exactly the article apps.
        SendToFriendSheet.accountSetupPresenter = EmailAccountSetupRoute()
        // The util card's email nudge goes to the same one place.
        UtilCardContentViewController.emailSetupLauncher = EmailSetupPresenter()
    }

    // MARK: - Lifecycle

    static func appDidLaunch() {
        // Keeps ArticleEntity's Spotlight index in sync with the saves list,
        // so saved articles are semantically discoverable and Siri can
        // resolve "my article about …" or "from …" without the app running.
        // An app that shows no article has nothing to index and no way to
        // open a result, so the index belongs to the article leg.
        ArticleSpotlightIndexWiring.install()
        // A save finished before its send went out is dropped from every
        // dequeue-on-read destination's queue. Both article apps owe this,
        // and central Luna's dequeue-on-read destination is a plugin.
        ReadStateSendReconciler.startObservingSaveChanges()
        retryPendingSends()
    }

    static func appDidEnterBackground() {
        // A finished-reading completion recorded during this session becomes
        // an archive move now, so the next launch starts settled. This is
        // the other half of the invariant `KindDeckProvider` documents: at
        // launch and at background.
        SavesStore.shared.archivePendingFinishedItems()
        retryPendingSends()
    }

    static func sceneDidForeground() {
        retryPendingSends()
        resumeIncompletePreloads()
    }

    /// Ereader sends that failed for want of network or an account.
    static func retryPendingSends() {
        ArticleSendCoordinator.shared.retryPendingSends()
    }

    /// Link preloading left incomplete (interrupted save / new depth).
    static func resumeIncompletePreloads() {
        PreloadCoordinator.shared.resumeIncomplete()
    }

    #if DEBUG
    /// `-openArchive <url>` debug root: the interactive archive reader.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? {
        let item = SavesStore.shared.addIfAbsent(urlString: articleURL.absoluteString)
            ?? SavesStore.shared.add(urlString: articleURL.absoluteString)
        let reader = ArchiveWebReaderViewController(articleURL: articleURL, itemID: item.id)
        return UINavigationController(rootViewController: reader)
    }
    #endif
}

/// Whichever setup a repeat press is still missing: the sign-in form first, the
/// Kindle address screen once an account is connected.
@MainActor
private struct KindleSetupPresenter: KindleSetupPresenting {
    func presentKindleSetup(from presenter: UIViewController) {
        guard EmailAccountStore.shared.isConfigured else {
            EmailAndKindleSettingsScreen.pushForAccountSetup(from: presenter)
            return
        }
        presenter.navigationController?.pushViewController(
            KindleSettingsScreen(), animated: true)
    }
}

/// The one email sign-in surface, for the util card's nudge.
@MainActor
private struct EmailSetupPresenter: EmailSetupPresenting {
    func presentEmailSetup(from presenter: UIViewController) {
        EmailAndKindleSettingsScreen.pushForAccountSetup(from: presenter)
    }
}

/// The export's image fetch: LunaReaderUI's downloader, joined to LunaSend's
/// exporters here because neither module can see the other.
private struct ArticleExportImageDownloader: ArticleExportImagePreparing {
    func preparedContent(
        _ content: ArticleContent, for item: SavedItem
    ) async -> ArticleContent {
        guard let referer = ArticleImageReferer.url(for: item, content: content) else {
            return content
        }
        return await ArticleImageDownloader.download(
            content, itemID: item.id, store: .shared, refererURL: referer)
    }
}

/// The read-aloud voice nudge's "Open Settings": the Audio settings page, which
/// only the app compiles.
@MainActor
private struct AudioSettingsRoute: VoiceSettingsPresenting {
    func presentVoiceSettings(from presenter: UIViewController) {
        let audio = AudioSettingsScreen()
        if let nav = presenter.navigationController {
            nav.pushViewController(audio, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: audio)
            presenter.present(nav, animated: true)
        }
    }
}

/// A bulk import's off-screen web unlock, the same one a tap would run.
private struct ImportArticleUnlocker: LinkImportArticleUnlocking {
    func unlockArticle(itemID: UUID, urlString: String) async -> Bool {
        await UnattendedArticleUnlock.unlock(itemID: itemID, urlString: urlString)
    }
}

/// The double save's "View immediately" file: LunaSend's exporter, which fetches
/// any article images that haven't landed yet before writing.
private struct ArticleIntentExporter: IntentArticleExporting {
    func exportedFileURL(
        for item: SavedItem, format: ArticleExportFormat
    ) async -> URL? {
        try? await ArticleExportService().writePreparingImagesWhenAvailable(
            format, for: item)
    }
}

/// A newly-ready article reaches the send pipeline, so Kindle/ereader auto-sends
/// keep firing. LunaSend is outside LunaReaderUI's tier, hence the bridge here.
private struct SendCoordinatorReadiness: ArticleReadinessObserving {
    func articleBecameReady(_ item: SavedItem) {
        ArticleSendCoordinator.shared.articleBecameReady(item)
    }
}

/// Bridges `IngestorArticleHandling` to the article-kind modules: persistence
/// in LunaReaderUI (`ArticleIngestHandler`, `PreloadCoordinator`) and sends
/// in LunaSend (`ArticleSendCoordinator`). The composition root is the one
/// place allowed to see both tiers at once.
private struct ArticleKindHandler: IngestorArticleHandling {
    private let handler = ArticleIngestHandler(
        readinessObserver: SendCoordinatorReadiness())

    func persistArticle(
        _ content: ArticleContent, html: String, for item: SavedItem,
        url: URL, store: SavesStore
    ) async {
        await handler.persistArticle(content, html: html, for: item, url: url, store: store)
    }

    func ingestDocument(_ item: SavedItem, store: SavesStore) async {
        await handler.ingestDocument(item, store: store)
    }

    func backfillMissingWebArchives(store: SavesStore) {
        handler.backfillMissingWebArchives(store: store)
    }

    func backfillMissingThumbnails(store: SavesStore) {
        handler.backfillMissingThumbnails(store: store)
    }

    func articleBecameReady(_ item: SavedItem) {
        ArticleSendCoordinator.shared.articleBecameReady(item)
    }

    func preloadPasteboard(content: ArticleContent, sourceURL: URL) {
        PreloadCoordinator.shared.preloadPasteboard(content: content, sourceURL: sourceURL)
    }

    func doubleSaveDestinationIDs() -> [String] {
        ArticleSendCoordinator.shared.doubleSaveDestinationIDs()
    }

    func sendToDestination(_ item: SavedItem, destinationID: String) async {
        await ArticleSendCoordinator.shared.send(item, toDestinationID: destinationID)
    }

    func isDestinationConfigured(_ destinationID: String) -> Bool {
        ArticleSendCoordinator.shared.isConfigured(destinationID: destinationID)
    }
}
