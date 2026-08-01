//
//  MediaKindComposition.swift
//  LunaMediaDownload
//

import LunaShareSurface
import Foundation

/// THE single definition of what registering the **media kind** (social / video /
/// audio links) means, for every surface of every media-handling app.
///
/// One call per root, so a surface cannot be wired half-way. See
/// `ArticleKindComposition` for why the per-surface lists were replaced.
public enum MediaKindComposition {

    /// Registers every media-kind entry. Media needs NO pipeline processor: it is
    /// classified from the URL alone (`PlatformRecognizer` / `DirectMediaURL`), so
    /// `IngestKindProcessors` has no media slot and only the extension presenter
    /// registers here. That asymmetry is exactly the kind of per-kind detail worth
    /// stating once, in one place, instead of re-deriving it at each root.
    ///
    /// Not included: `IngestorKindHandlers.media`, the app-shell persistence
    /// handler, which is built from app-shell types and stays in `KindWiring+*`.
    @MainActor
    public static func install() {
        ShareKindPresenters.media = MediaSharePresenter()
    }
}

/// Adapts the protocol-free `ExtensionMediaPresenter` to the kind-neutral
/// `ShareMediaPresenting` surface protocol. Previously copy-pasted into four
/// composition roots; `LunaShareSurface` is kind-agnostic, so the kind module
/// owns its own conformance.
struct MediaSharePresenter: ShareMediaPresenting {
    private let presenter = ExtensionMediaPresenter()

    func presentNonTextual(urlString: String, host: ExtensionHost) {
        presenter.presentNonTextual(
            urlString: urlString, interactive: host.readerMode != nil,
            presentModally: { [weak host] in host?.presentModally($0) },
            completeOnExit: { [weak host] in host?.completeSilently() },
            autoDownloadThenComplete: { [weak host] in host?.autoDownloadThenComplete(urlString: $0) })
    }

    func shouldAutoDownload(urlString: String) -> Bool {
        presenter.shouldAutoDownload(urlString: urlString)
    }

    func startAutoDownload(urlString: String) async {
        await presenter.startAutoDownload(urlString: urlString)
    }
}
