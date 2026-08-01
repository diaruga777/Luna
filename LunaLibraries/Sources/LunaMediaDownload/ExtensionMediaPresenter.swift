//
//  ExtensionMediaPresenter.swift
//  LunaMediaDownload
//

import UIKit

/// The media-kind side of the extension surfaces: the saved-non-textual screen
/// and the auto-download handoff. Protocol-free — each extension target's
/// composition root (`ShareEntry+*` / `ActionEntry+*`) wraps it in a small
/// adapter conforming to `ShareMediaPresenting` (LunaShareSurface), the same
/// shape as the `IngestKindProcessors` / `IngestorKindHandlers` wiring. Host
/// side effects arrive as closures so this module never sees the surface's
/// `ExtensionHost`.
@MainActor
public final class ExtensionMediaPresenter {

    public init() {}

    /// Routes a saved video/social item. Downloadable media always opens the
    /// saved-content screen on BOTH extension surfaces (`interactive` is the
    /// action extension) so the user can explicitly choose the media download;
    /// non-downloadable items retain the share extension's silent-save terminal
    /// (`autoDownloadThenComplete`, a confirm when nothing is downloadable).
    ///
    /// Leaving the saved-content screen completes SILENTLY (`completeOnExit`,
    /// not the host's saved-checkmark chrome): that screen's own header already
    /// says "Saved to Luna", so the badge was a second confirmation card
    /// animating in over a screen the user had just dismissed.
    public func presentNonTextual(
        urlString: String, interactive: Bool,
        presentModally: (UIViewController) -> Void,
        completeOnExit: @escaping () -> Void,
        autoDownloadThenComplete: (String) -> Void
    ) {
        if interactive || MediaDownloadablePlatform.supports(urlString) {
            presentModally(SavedNonTextualViewController(
                articleURLString: urlString, onDone: completeOnExit))
        } else {
            autoDownloadThenComplete(urlString)
        }
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
}
