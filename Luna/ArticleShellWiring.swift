//
//  ArticleShellWiring.swift
//  Luna
//
//  The article kind's half of the app shell: every seam an article-handling app
//  installs at launch, and the lifecycle work articles owe at each of
//  `KindWiring`'s fixed points. Compiled ONLY into the targets that link the
//  article kind (Luna, LunaReader) — the other two exclude this file by
//  membership exception, exactly as they exclude `Reader/ArticleCardPresenter
//  .swift` and the rest of the article shell.
//
//  A `KindWiring+<App>` variant installs the article KIND PACK
//  (`ArticleKindComposition`) and the article CARD presenter itself, then calls
//  the legs below; nothing article-specific is written twice.
//

import LunaArchiveReader
import LunaArticleIngest
import LunaAudioPlayback
import LunaIngest
import LunaMailAccount
import LunaMailTransport
import LunaModels
import LunaReaderUI
import LunaReadingList
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
        ReadingListStore.shared.archivePendingFinishedItems()

        // Send-to-Kindle emails go out through the connected email account.
        // LunaSend sits below LunaMailTransport, so the transport factory is
        // injected here (extensions leave it nil → Kindle sends are no-ops there).
        ArticleEmailTransportProvider.installed = MailFactoryTransportProvider()

        // New audio-playback stack (claudedocs/audio-playback-plan.md, Phase 2):
        // install the autoplay queue provider and register the Now Playing /
        // remote-command coordinator. Registration must happen at launch (not
        // lazily) so a cold background relaunch from a lock-screen play command
        // can restore the persisted session. Read-aloud (the app-wide center,
        // its background session, the window mini-player) belongs exclusively
        // to article-handling apps — the Downloader / Price Tracker leave
        // `ReaderAudioLauncher.center` nil, keeping the shared readers on their
        // legacy self-contained `SpeechController` path.
        AudioPlaybackWiring.install()
        // Phase 4 (trimming): opportunistic script-cache builder, wired
        // right after playback so its scriptProvider/scriptPrefetchHandler
        // seams are set before anything could call into the center.
        AudioScriptPipelineWiring.install()

        // The Action Button double save (claudedocs/double-save.md): its
        // "View immediately" returns an article document, and Kindle needs
        // the account/Kindle setup screens. Both are article-only, so both are
        // installed here — matching `ActionButtonIntentSupport.doubleSaveSurface`,
        // which arms double save in exactly the apps that link LunaSend.
        ActionButtonIntentSupport.articleExporter = { item, format in
            try? await ArticleExportService().writePreparingImagesWhenAvailable(
                format, for: item)
        }
        // Exports fetch the article images that haven't landed yet rather than
        // shipping a file with none. The downloader is LunaReaderUI's and the
        // exporters are LunaSend's, so the composition root joins them.
        ArticleExportImages.preparer = { content, item in
            guard let referer = ArticleImageReferer.url(for: item, content: content) else {
                return content
            }
            return await ArticleImageDownloader.download(
                content, itemID: item.id, store: .shared, refererURL: referer)
        }
        DoubleSaveSettingsSupport.kindleSetupLauncher = { presenter in
            guard EmailAccountStore.shared.isConfigured else {
                EmailAndKindleSettingsScreen.pushForAccountSetup(from: presenter)
                return
            }
            presenter.navigationController?.pushViewController(
                KindleSettingsScreen(), animated: true)
        }

        // A bulk import's pass over the saves that came back hard-paywalled:
        // the same web unlock a tap would run, off-screen and giving up on any
        // CAPTCHA (`claudedocs/import-export.md`). Article apps only — there is
        // no article save to unlock anywhere else.
        LinkImportRunner.articleUnlocker = { itemID, urlString in
            await UnattendedArticleUnlock.unlock(itemID: itemID, urlString: urlString)
        }

        // Voice status and installation live on the Audio settings page.
        VoiceFirstRunPrompt.openVoiceSettings = { presenter in
            let audio = AudioSettingsScreen()
            if let nav = presenter.navigationController {
                nav.pushViewController(audio, animated: true)
            } else {
                let nav = UINavigationController(rootViewController: audio)
                presenter.present(nav, animated: true)
            }
        }

        // Sending needs a connected email account: an attempted send without one
        // redirects to the screen that connects it (its Sharing Account section is
        // the sign-in form until then). Only the email-sending apps compile that
        // screen, and they are exactly the article apps.
        SendToFriendSheet.accountSetupPresenter = EmailAccountSetupRoute()
        // The util card's email nudge goes to the same one place.
        UtilCardContentViewController.emailSetupLauncher = { presenter in
            EmailAndKindleSettingsScreen.pushForAccountSetup(from: presenter)
        }
    }

    // MARK: - Lifecycle

    static func appDidLaunch() {
        // Phase 7 (Siri): keep ArticleEntity's Spotlight index in sync with the
        // reading list so saved articles are semantically discoverable and Siri
        // can resolve "my article about …"/"from …" without the app running.
        // An app that shows no article has nothing to index and no way to open
        // a result, so the index belongs to the article leg.
        ArticleSpotlightIndexWiring.install()
        retryPendingSends()
    }

    static func appDidEnterBackground() {
        // A finished-reading completion recorded during this session becomes an
        // archive move now, so the next launch starts settled — the other half
        // of the invariant `KindDeckProvider` documents (at launch AND at
        // background).
        ReadingListStore.shared.archivePendingFinishedItems()
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
        let item = ReadingListStore.shared.addIfAbsent(urlString: articleURL.absoluteString)
            ?? ReadingListStore.shared.add(urlString: articleURL.absoluteString)
        let reader = ArchiveWebReaderViewController(articleURL: articleURL, itemID: item.id)
        return UINavigationController(rootViewController: reader)
    }
    #endif
}

/// Bridges `IngestorArticleHandling` to the article-kind modules: persistence
/// in LunaReaderUI (`ArticleIngestHandler`, `PreloadCoordinator`) and sends in
/// LunaSend (`ArticleSendCoordinator`) — the composition root is the one place
/// allowed to see both tiers at once.
private struct ArticleKindHandler: IngestorArticleHandling {
    private let handler = ArticleIngestHandler(articleBecameReady: {
        ArticleSendCoordinator.shared.articleBecameReady($0)
    })

    func persistArticle(
        _ content: ArticleContent, html: String, for item: ReadingListItem,
        url: URL, store: ReadingListStore
    ) async {
        await handler.persistArticle(content, html: html, for: item, url: url, store: store)
    }

    func ingestDocument(_ item: ReadingListItem, store: ReadingListStore) async {
        await handler.ingestDocument(item, store: store)
    }

    func backfillMissingWebArchives(store: ReadingListStore) {
        handler.backfillMissingWebArchives(store: store)
    }

    func backfillMissingThumbnails(store: ReadingListStore) {
        handler.backfillMissingThumbnails(store: store)
    }

    func articleBecameReady(_ item: ReadingListItem) {
        ArticleSendCoordinator.shared.articleBecameReady(item)
    }

    func preloadPasteboard(content: ArticleContent, sourceURL: URL) {
        PreloadCoordinator.shared.preloadPasteboard(content: content, sourceURL: sourceURL)
    }

    func doubleSaveDestinationIDs() -> [String] {
        ArticleSendCoordinator.shared.doubleSaveDestinationIDs()
    }

    func sendToDestination(_ item: ReadingListItem, destinationID: String) async {
        await ArticleSendCoordinator.shared.send(item, toDestinationID: destinationID)
    }

    func isDestinationConfigured(_ destinationID: String) -> Bool {
        ArticleSendCoordinator.shared.isConfigured(destinationID: destinationID)
    }
}
