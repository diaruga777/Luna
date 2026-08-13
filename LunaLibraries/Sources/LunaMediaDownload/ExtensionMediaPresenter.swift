//
//  ExtensionMediaPresenter.swift
//  LunaMediaDownload
//

import LunaModels
import LunaShareSurface
import UIKit

/// The media-kind side of the extension surfaces: the saved-non-textual screen
/// and the auto-download handoff. Conforms to `ShareMediaPresenting`
/// (LunaShareSurface) directly, so `MediaKindComposition.install()` registers
/// it as-is.
@MainActor
public final class ExtensionMediaPresenter: ShareMediaPresenting {

    public init() {}

    /// Routes a saved video/social item. Downloadable media always opens the
    /// saved-content screen on BOTH extension surfaces (`host.readerMode` is
    /// non-nil on the action extension — which is also the only one that
    /// offers the system share sheet, the share extension's user having just
    /// come from one) so the user can explicitly choose the media download;
    /// non-downloadable items retain the share extension's silent-save terminal
    /// (`host.autoDownloadThenComplete`, a confirm when nothing is downloadable).
    ///
    /// Leaving the saved-content screen completes SILENTLY (`host.completeSilently`,
    /// not the host's saved-checkmark chrome): that screen's own header already
    /// says "Saved to Luna", so the badge was a second confirmation card
    /// animating in over a screen the user had just dismissed.
    public func presentNonTextual(urlString: String, host: ExtensionHost) {
        let interactive = host.readerMode != nil
        if interactive || MediaDownloadablePlatform.supports(urlString) {
            host.presentModally(SavedNonTextualViewController(
                articleURLString: urlString, showsSystemShare: interactive,
                onDone: { [weak host] in host?.completeSilently() }))
        } else {
            host.autoDownloadThenComplete(urlString: urlString)
        }
    }

    /// The deterministic onboarding post is still shown by the production
    /// saved-media controller. Only its downloaded file is supplied up front;
    /// no network request, reading-list write, Photos write, or background
    /// transfer is involved in a rehearsal.
    public func presentPracticeVideo(videoURL: URL, host: ExtensionHost) -> Bool {
        let interactive = host.readerMode != nil
        host.presentModally(SavedNonTextualViewController(
            articleURLString: ShareSetupPractice.instaTokURLString,
            showsSystemShare: interactive,
            practiceVideoURL: videoURL,
            onDone: { [weak host] in host?.completeSilently() }))
        return true
    }

    /// Whether a background auto-download should start for `urlString` (the
    /// auto-download setting is on for the platform); false means the host
    /// just confirms the save.
    public func shouldAutoDownload(urlString: String) -> Bool {
        MediaAutoDownloader.isEnabled(forURLString: urlString)
    }

    /// The background auto-download handoff for `urlString`: hands the media
    /// download to the system background-transfer service and Live Activity.
    public func startAutoDownload(urlString: String) async {
        _ = await MediaAutoDownloader.startLiveActivityIfEnabled(forURLString: urlString)
    }

    public func preloadDownload(forURLString urlString: String) {
        MediaPreloadCache.shared.preload(urlString: urlString)
    }

    /// Everything the media kind may have written for this link: the durable
    /// library entry (whose own delete removes its files) and the
    /// already-downloaded marker that would otherwise make the next save skip
    /// its fetch. The reading-list row itself belongs to the caller — it is
    /// kind-neutral.
    public func deleteSavedContents(forURLString urlString: String) {
        MediaPreloadCache.shared.discard(urlString: urlString)
        if let item = SavedMediaStore.shared.existingDownloadedItem(
            forURLString: urlString) {
            SavedMediaStore.shared.delete(item)
        }
        AutoDownloadSettings.unmarkDownloaded(urlString)
    }
}
