//
//  AppReaderProviders.swift
//  Luna
//

import LunaSocialUI
import LunaReadingList
import LunaReaderUI
import LunaStorage
import UIKit

/// Main-app sharing provider: pick recipients and send a Luna email (via
/// `SendToFriendSheet` → `EmailShareCenter`), or export/share the link. Injected
/// into readers in the main app; the share extension passes nil instead.
public final class AppReaderShareProvider: ReaderShareProviding {
    public static let shared = AppReaderShareProvider()

    public func suggestedFriendName(forURLString urlString: String) -> String? { nil }

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
            suggestedFriendName: nil,
            includeEbook: isArticle,
            onSendToSuggested: {},
            onPickFriend: { [weak presenter] in
                guard let presenter else { return }
                SendToFriendSheet.present(
                    from: presenter, item: item,
                    urlString: urlString, title: title)
            },
            onShareLink: { [weak presenter] in
                guard let presenter else { return }
                SendToFriendSheet.shareLink(
                    urlString: urlString, from: presenter, sourceView: sourceView)
            },
            onShareEbook: { [weak presenter] in
                guard let presenter, let item else { return }
                ArticleExportService().presentShareSheet(
                    for: item, from: presenter, sourceView: sourceView)
            })
        ReaderShareSheet.present(from: presenter, rows: rows)
    }

    public func sendToSuggestedFriend(urlString: String, title: String?, from presenter: UIViewController) {
        let item = ReadingListStore.shared.item(forURLString: urlString)
        SendToFriendSheet.present(
            from: presenter, item: item, urlString: urlString, title: title)
    }

    public func saveLink(urlString: String) {
        Task { await ReadingListIngestor.shared.handleSavePress(urlString: urlString) }
    }
}
