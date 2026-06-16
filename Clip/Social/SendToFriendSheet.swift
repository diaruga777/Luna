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
            // Share a clickreader:// deep link so recipients with Click installed
            // open it straight in the reader (falls back to the plain URL if the
            // link can't be built).
            let shared = ClickDeepLink.readLink(forArticleURL: urlString)?.absoluteString ?? urlString
            let activity = UIActivityViewController(
                activityItems: [shared], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = sourceView
            presenter.present(activity, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        sheet.popoverPresentationController?.sourceView = sourceView
        presenter.present(sheet, animated: true)
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
                showTransientConfirmation(
                    "Sent to \(friend.card.username)", from: presenter)
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

    /// A title-only alert that dismisses itself — lightweight send confirmation.
    @MainActor
    private static func showTransientConfirmation(
        _ text: String, from presenter: UIViewController
    ) {
        let alert = UIAlertController(title: text, message: nil, preferredStyle: .alert)
        presenter.present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak alert] in
            alert?.dismiss(animated: true)
        }
    }
}
