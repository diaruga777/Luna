//
//  ShareEntry+Downloader.swift
//
//  The extension's principal class (Info.plist names the stable @objc name
//  `LunaShareEntry`). EXACTLY ONE variant is compiled into each host's
//  extension target (per-target membership exceptions on the shared folder),
//  registering the per-kind pipeline processors AND extension presenters that
//  host's app handles — the registries mirror the link set.
//

import LunaShareSurface
import UIKit
import LunaMediaDownload

@objc(LunaShareEntry)
final class ShareEntry: ShareViewController {
    override init(nibName: String?, bundle: Bundle?) {
        // Media needs no web-processing pipeline stage (URL-only classification);
        // only the extension presenter registers.
        ShareKindPresenters.media = MediaPresenterAdapter()
        super.init(nibName: nibName, bundle: bundle)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Adapts the protocol-free `ExtensionMediaPresenter` (LunaMediaDownload) to
/// `ShareMediaPresenting`.
private struct MediaPresenterAdapter: ShareMediaPresenting {
    private let presenter = ExtensionMediaPresenter()

    func presentNonTextual(urlString: String, host: ExtensionHost) {
        presenter.presentNonTextual(
            urlString: urlString, interactive: host.readerMode != nil,
            presentModally: { [weak host] in host?.presentModally($0) },
            confirmSavedThenComplete: { [weak host] in host?.confirmSavedThenComplete() },
            autoDownloadThenComplete: { [weak host] in host?.autoDownloadThenComplete(urlString: $0) })
    }

    func shouldAutoDownload(urlString: String) -> Bool {
        presenter.shouldAutoDownload(urlString: urlString)
    }

    func startAutoDownload(urlString: String) async {
        await presenter.startAutoDownload(urlString: urlString)
    }
}
