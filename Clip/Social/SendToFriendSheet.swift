//
//  SendToFriendSheet.swift
//  Clip
//

import ClipDesignSystem
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
        // Share Link is a separate menu item at the call sites — this is the friend
        // picker.
        presentFriendPicker(
            from: presenter, sourceView: sourceView, urlString: urlString, title: title)
    }

    /// Presents the modern friend-picker sheet; picking one sends the article to
    /// their reading list.
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
        let sheet = FriendPickerSheet(friends: friends) { [weak presenter] friend in
            guard let presenter else { return }
            deliver(urlString: urlString, title: title, to: friend, presenter: presenter)
        }
        presenter.present(sheet, animated: true)
    }

    /// Shares the plain article URL — no Queue deep link, no accessory text — so it
    /// behaves like any normal link share.
    static func shareLink(urlString: String, from presenter: UIViewController, sourceView: UIView) {
        let shared: Any = URL(string: urlString) ?? urlString
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
