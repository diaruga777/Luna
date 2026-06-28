//
//  AppReaderProviders.swift
//  Clip
//

import ClipReadingList
import ClipReaderUI
import ClipSemantic
import ClipSocial
import ClipDesignSystem
import ClipStorage
import UIKit

/// Main-app sharing provider, backed by the social stack (ShareSuggestionStore
/// + SendToFriendSheet → CloudKit). Injected into readers in the main app; the
/// share extension passes nil instead, so neither this type nor CloudKit is
/// compiled into the extension.
final class AppReaderShareProvider: ReaderShareProviding {
    static let shared = AppReaderShareProvider()

    func suggestedFriendName(forURLString urlString: String) -> String? {
        bestFriend(forURLString: urlString)?.username
    }

    /// The friend to surface at the end of an article: the same-site/-channel
    /// streak suggestion, else a cached content-similarity match (no embedding).
    private func bestFriend(forURLString urlString: String) -> (uuid: UUID, username: String)? {
        let item = ReadingListStore.shared.item(forURLString: urlString)
        if let streak = ShareSuggestionStore.shared.suggestedFriend(
            forURLString: urlString, channelName: item?.channelName) {
            return streak
        }
        if let itemID = item?.id {
            return SemanticIndexer.shared.cachedSuggestion(forItemID: itemID)
        }
        return nil
    }

    func presentShareSheet(
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
        let suggestion = bestFriend(forURLString: urlString)
        let rows = ReaderShareSheet.rows(
            suggestedFriendName: suggestion?.username,
            includeEbook: isArticle,
            onSendToSuggested: { [weak presenter] in
                guard let presenter, let suggestion else { return }
                SendToFriendSheet.sendToFriend(
                    uuid: suggestion.uuid, urlString: urlString, title: title, from: presenter)
            },
            onPickFriend: { [weak presenter] in
                guard let presenter else { return }
                SendToFriendSheet.presentFriendPicker(
                    from: presenter, sourceView: sourceView, urlString: urlString, title: title)
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

    func sendToSuggestedFriend(urlString: String, title: String?, from presenter: UIViewController) {
        guard let suggestion = bestFriend(forURLString: urlString) else { return }
        SendToFriendSheet.sendToFriend(
            uuid: suggestion.uuid, urlString: urlString, title: title, from: presenter)
    }

    func saveLink(urlString: String) {
        Task { await ReadingListIngestor.shared.handleSavePress(urlString: urlString) }
    }
}

/// Main-app gaze-tracker factory: a real `EyeGazeWordTracker` when eye tracking
/// is enabled, else nil. The extension never uses this (no camera/ARKit).
enum AppGazeTracker {
    static let factory: GazeTrackerFactory = { textView, wordMap, seed in
        guard ReaderSettings.eyeTrackingEnabled else { return nil }
        return EyeGazeWordTracker(textView: textView, wordMap: wordMap, seedWordIndex: seed)
    }
}

extension EyeGazeWordTracker: GazeTracking {}
