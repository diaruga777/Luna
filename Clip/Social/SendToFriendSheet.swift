//
//  SendToFriendSheet.swift
//  Clip
//

import UIKit

/// The shared "share this article" sheet used by the reading list and the
/// reader: pick a friend to send via Clip messaging, or fall back to the
/// system share sheet with the plain URL.
enum SendToFriendSheet {

    static func present(
        from presenter: UIViewController,
        sourceView: UIView,
        urlString: String,
        title: String?
    ) {
        let friends = FriendsStore.shared.items()

        let sheet = UIAlertController(
            title: title ?? urlString,
            message: friends.isEmpty
                ? "Add friends from the Friends screen to send articles directly."
                : "Send to a friend's reading list, or share the link.",
            preferredStyle: .actionSheet)

        for friend in friends {
            sheet.addAction(UIAlertAction(
                title: "Send to \(friend.card.username)", style: .default
            ) { _ in
                deliver(urlString: urlString, title: title, to: friend, presenter: presenter)
            })
        }

        sheet.addAction(UIAlertAction(title: "Share Link…", style: .default) { _ in
            shareLink(urlString: urlString, from: presenter, sourceView: sourceView)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        sheet.popoverPresentationController?.sourceView = sourceView
        presenter.present(sheet, animated: true)
    }

    /// Presents an action sheet of just the user's friends; picking one sends the
    /// article to their reading list. Used by the reader's share sheet (where
    /// "Share Link…" is already a separate option).
    static func presentFriendPicker(
        from presenter: UIViewController, sourceView: UIView, urlString: String, title: String?
    ) {
        let friends = FriendsStore.shared.items()
        guard !friends.isEmpty else {
            let alert = UIAlertController(
                title: "No Friends Yet",
                message: "Add friends from the Friends screen to send articles directly.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            presenter.present(alert, animated: true)
            return
        }
        let sheet = UIAlertController(
            title: title ?? urlString, message: nil, preferredStyle: .actionSheet)
        for friend in friends {
            sheet.addAction(UIAlertAction(
                title: "Send to \(friend.card.username)", style: .default
            ) { _ in
                deliver(urlString: urlString, title: title, to: friend, presenter: presenter)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView
        presenter.present(sheet, animated: true)
    }

    /// Shares the original URL (works for everyone) plus a `clickreader://` deep
    /// link that opens the article in Queue for people who have it.
    static func shareLink(urlString: String, from presenter: UIViewController, sourceView: UIView) {
        let shared: String
        if let deepLink = ClickDeepLink.readLink(forArticleURL: urlString)?.absoluteString {
            shared = "\(urlString)\n\nRead on Queue: \(deepLink)"
        } else {
            shared = urlString
        }
        let activity = UIActivityViewController(
            activityItems: [shared], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = sourceView
        presenter.present(activity, animated: true)
    }

    /// One-tap send to a specific friend (the end-of-article suggestion),
    /// resolving the friend by UUID. Falls back silently if the friend is gone.
    static func sendToFriend(
        uuid: UUID, urlString: String, title: String?, from presenter: UIViewController
    ) {
        guard let friend = FriendsStore.shared.friend(withUUID: uuid) else { return }
        deliver(urlString: urlString, title: title, to: friend, presenter: presenter)
    }

    private static func deliver(
        urlString: String, title: String?, to friend: Friend,
        presenter: UIViewController
    ) {
        Task { @MainActor in
            guard await ICloudGate.requireICloud(presenting: presenter) else { return }
            do {
                try await SocialMessageCenter.shared.sendArticle(
                    urlString: urlString, title: title, to: friend)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Toast.show("Sent to \(friend.card.username)", from: presenter)
            } catch {
                let alert = UIAlertController(
                    title: "Couldn't Send",
                    message: "\(error)",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                presenter.present(alert, animated: true)
            }
        }
    }
}
