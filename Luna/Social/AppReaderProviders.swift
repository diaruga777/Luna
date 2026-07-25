//
//  AppReaderProviders.swift
//  Luna
//

import LunaSocialUI
import LunaReadingList
import LunaModels
import LunaReaderUI
import LunaSend
import LunaStorage
import LunaURLClassification
import UIKit

/// Main-app sharing provider: pick recipients and send a Luna email (via
/// `SendToFriendSheet` → `EmailShareCenter`), or export/share the link. Injected
/// into readers in the main app; the share extension passes nil instead.
public final class AppReaderShareProvider: ReaderShareProviding {
    public static let shared = AppReaderShareProvider()

    public var providesShareMenu: Bool { true }

    public func shareMenu(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView
    ) -> UIMenu? {
        // A no-url text article has exactly one verb, and it's already a system
        // sheet — a one-item popover in front of it would be pure ceremony.
        guard let rows = rows(
            urlString: urlString, title: title, from: presenter, sourceView: sourceView)
        else { return nil }
        return ReaderShareSheet.menu(rows: rows)
    }

    public func presentShareSheet(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView
    ) {
        guard let rows = rows(
            urlString: urlString, title: title, from: presenter, sourceView: sourceView)
        else {
            presentEbookOnlyShare(urlString: urlString, from: presenter, sourceView: sourceView)
            return
        }
        ReaderShareSheet.present(from: presenter, rows: rows)
    }

    /// The one option list behind both the menu and the fallback sheet. Nil means the
    /// item is a no-url text article (email/document) whose only share is the eBook
    /// export — see `presentEbookOnlyShare`.
    private func rows(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView
    ) -> [ReaderShareSheet.Row]? {
        let item = ReadingListStore.shared.item(forURLString: urlString)
        // eBook export is for readable articles/documents only — never media posts.
        let isArticle = item.map { !$0.isPlatformItem } ?? false
        if let item, isArticle, !item.isShareable { return nil }
        return ReaderShareSheet.rows(
            includeEbook: isArticle,
            onPickFriend: { [weak presenter] in
                guard let presenter else { return }
                SendToFriendSheet.present(
                    from: presenter, item: item,
                    urlString: urlString, title: title)
            },
            onShareLink: { [weak presenter] in
                guard let presenter else { return }
                SendToFriendSheet.shareLink(
                    urlString: urlString,
                    sharedURLString: Self.appClipShareURLString(for: urlString, item: item),
                    from: presenter, sourceView: sourceView)
            },
            onCopyLink: { [weak presenter] in
                guard let presenter else { return }
                SendToFriendSheet.copyLink(urlString: urlString, from: presenter)
            },
            onShareEbook: { [weak presenter] in
                guard let presenter, let item else { return }
                ArticleExportService().presentShareSheet(
                    for: item, from: presenter, sourceView: sourceView)
            })
    }

    /// A no-url text article (email/document) can only leave as an eBook, so skip
    /// the option list and go straight to the export sheet.
    private func presentEbookOnlyShare(
        urlString: String, from presenter: UIViewController, sourceView: UIView
    ) {
        guard let item = ReadingListStore.shared.item(forURLString: urlString) else { return }
        ArticleExportService().presentShareSheet(
            for: item, from: presenter, sourceView: sourceView)
    }

    public func saveLink(urlString: String) {
        Task { await ReadingListIngestor.shared.handleSavePress(urlString: urlString) }
    }

    private static func appClipShareURLString(for urlString: String, item: ReadingListItem?) -> String? {
        LunaAppClipInvocationURL.shareURL(
            for: urlString,
            destination: item?.isPlatformItem == true ? .downloader : .reader
        )?.absoluteString
    }
}
