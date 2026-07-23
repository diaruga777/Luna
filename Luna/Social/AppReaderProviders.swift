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

    public func presentShareSheet(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView
    ) {
        let item = ReadingListStore.shared.item(forURLString: urlString)
        // eBook export is for readable articles/documents only — never media posts.
        let isArticle = item.map { !$0.isPlatformItem } ?? false
        // No-url text articles (email/document) can only be shared as an eBook.
        if let item, isArticle, !item.isShareable {
            ArticleExportService().presentShareSheet(
                for: item, from: presenter, sourceView: sourceView)
            return
        }
        let rows = ReaderShareSheet.rows(
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
        ReaderShareSheet.present(from: presenter, rows: rows)
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
