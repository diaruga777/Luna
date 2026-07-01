//
//  ExtensionReaderShareProvider.swift
//  LunaShare
//

import LunaReaderUI
import UIKit

/// The action extension's reader sharing: lets the user share the article they
/// just read with a Luna friend or via the system link share. The extension
/// has no CloudKit/crypto, so a friend send is QUEUED to the App Group
/// (`PendingFriendShareWriter`) and the main app delivers it on next launch.
/// There's no suggestion engine in the extension, so no one-tap suggested send.
public final class ExtensionReaderShareProvider: ReaderShareProviding {

    public func suggestedFriendName(forURLString urlString: String) -> String? { nil }

    public func presentShareSheet(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView
    ) {
        let friends = ExtensionFriendsReader.friends()
        let sheet = UIAlertController(
            title: title ?? urlString,
            message: friends.isEmpty
                ? "Add friends in Luna to send articles directly."
                : "Send to a friend's Luna reading list, or share the link.",
            preferredStyle: .actionSheet)

        for friend in friends {
            sheet.addAction(UIAlertAction(
                title: "Send to \(friend.username)", style: .default
            ) { _ in
                PendingFriendShareWriter.enqueue(friendUUID: friend.uuid, urlString: urlString)
                Self.confirmQueued(friendName: friend.username, from: presenter)
            })
        }

        sheet.addAction(UIAlertAction(title: "Share Link…", style: .default) { _ in
            // Plain URL only — no Luna deep link, no accessory text.
            let shared: Any = URL(string: urlString) ?? urlString
            let activity = UIActivityViewController(
                activityItems: [shared], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = sourceView
            presenter.present(activity, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView
        presenter.present(sheet, animated: true)
    }

    public func sendToSuggestedFriend(urlString: String, title: String?, from presenter: UIViewController) {
        // No suggestion engine in the extension — nothing to do.
    }

    public func saveLink(urlString: String) {
        // No ingestor in the extension — queue the URL; the main app ingests it.
        SharedReadingListAppender.append(urlString: urlString)
    }

    /// The send is queued, not sent yet (no CloudKit here) — say so honestly.
    private static func confirmQueued(friendName: String, from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "Will Send to \(friendName)",
            message: "It'll be delivered the next time you open Luna.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }
}
