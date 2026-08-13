//
//  SendToFriendSheet.swift
//  LunaSocialUI
//

import LunaSocial
import LunaSaves
import LunaModels
import LunaDesignSystem
import UIKit

/// Shows the screen where a sending account gets connected (Settings → Email &
/// Sending, whose Sharing Account section is the sign-in form until then). The
/// screen is the app shell's, so the app installs a conformer.
public protocol AccountSetupPresenting {
    /// Navigates `presenter` to the account-setup screen.
    func presentAccountSetup(from presenter: UIViewController)
}

/// The shared "share this" entry point used by the saves list and the reader:
/// pick recipients and send a Luna email, or fall back to the system share sheet
/// with the plain URL.
public enum SendToFriendSheet {

    /// The installed route to account setup, so an attempted send with no account
    /// configured can redirect there. Installed only by the `KindWiring` variants
    /// of the apps that send email at all — the others never reach this path.
    public static var accountSetupPresenter: (any AccountSetupPresenting)?

    /// Presents the recipient picker for a saved item (preferred — sends
    /// the item's rich content), or a bare URL when no item is available.
    public static func present(
        from presenter: UIViewController,
        item: SavedItem? = nil,
        urlString: String,
        title: String?
    ) {
        guard EmailShareCenter.shared.isConfigured else {
            promptAccountSetup(from: presenter)
            return
        }
        let recentRecipients = RecentFriendRecipientsStore.shared.items(limit: 5).filter {
            !FriendsStore.shared.isBlocked($0.email)
        }
        guard !recentRecipients.isEmpty else {
            presentFriendPicker(from: presenter, item: item, urlString: urlString, title: title)
            return
        }
        presentRecentRecipients(
            recentRecipients, from: presenter, item: item, urlString: urlString, title: title)
    }

    /// Copies the URL directly to the clipboard, then shows the confirmation.
    public static func copyLink(urlString: String, from presenter: UIViewController) {
        copyToPasteboard(urlString: urlString)
        presentCopiedConfirmation(from: presenter)
    }

    /// Writes the URL to the pasteboard and fires the success haptic — the part that
    /// must happen synchronously the instant the user taps, before any menu dismissal.
    private static func copyToPasteboard(urlString: String) {
        UIPasteboard.general.string = urlString
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Shows the transient "Copied" confirmation: a toast near the bottom of the
    /// screen. It used to be a modal alert, which could only be presented AFTER
    /// whatever menu or sheet spawned it had finished dismissing — hence the
    /// noticeable lag between picking Copy link and being told about it. A toast is
    /// an ordinary non-interactive subview, so it can go up immediately, even while
    /// a menu is still wiping away.
    private static func presentCopiedConfirmation(from presenter: UIViewController) {
        LunaToast.show(L10n.string("Sharing_sendToFriend_copiedToast"), from: presenter)
    }

    private static func presentFriendPicker(
        from presenter: UIViewController,
        item: SavedItem?,
        urlString: String,
        title: String?
    ) {
        let picker = RecipientPickerViewController { emails in
            guard !emails.isEmpty else { return }
            deliver(item: item, urlString: urlString, title: title, to: emails, from: presenter)
        }
        let nav = UINavigationController(rootViewController: picker)
        presenter.present(nav, animated: true)
    }

    private static func presentRecentRecipients(
        _ recipients: [RecentFriendRecipientsStore.Recipient],
        from presenter: UIViewController,
        item: SavedItem?,
        urlString: String,
        title: String?
    ) {
        let sheet = UIAlertController(
            title: L10n.string("Sharing_sendToFriend_recentSheetTitle"), message: nil, preferredStyle: .actionSheet)
        for recipient in recipients {
            sheet.addAction(UIAlertAction(title: recipient.email, style: .default) { _ in
                deliver(item: item, urlString: urlString, title: title, to: [recipient.email], from: presenter)
            })
        }
        sheet.addAction(UIAlertAction(title: L10n.string("Sharing_sendToFriend_otherOptionAction"), style: .default) { _ in
            presentFriendPicker(from: presenter, item: item, urlString: urlString, title: title)
        })
        sheet.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = presenter.view
        presenter.present(sheet, animated: true)
    }

    /// Shares a URL via the system share sheet. `sharedURLString` lets callers hand
    /// out an App Clip invocation URL while keeping Copy Link on the plain URL.
    public static func shareLink(
        urlString: String,
        sharedURLString: String? = nil,
        from presenter: UIViewController,
        sourceView: UIView?
    ) {
        let urlToShare = sharedURLString ?? urlString
        let shared: Any = URL(string: urlToShare) ?? urlToShare
        LunaShareSheet.present(
            items: [shared], from: presenter, anchor: .view(sourceView ?? presenter.view))
    }

    // MARK: - Delivery

    private static func deliver(
        item: SavedItem?, urlString: String, title: String?,
        to emails: [String], from presenter: UIViewController
    ) {
        Task { @MainActor in
            do {
                if let item {
                    try await EmailShareCenter.shared.send(item: item, to: emails)
                } else {
                    try await EmailShareCenter.shared.share(urlString: urlString, title: title, to: emails)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                presentError(error, from: presenter)
            }
        }
    }

    /// Sending needs an account, so go straight to where one is connected rather
    /// than asking permission to go there. Only a surface with no route installed
    /// (an app extension, which can't navigate the app's settings) explains in an
    /// alert instead.
    private static func promptAccountSetup(from presenter: UIViewController) {
        guard let accountSetupPresenter else {
            let alert = UIAlertController(
                title: L10n.string("Common_setUpEmailFirst"),
                message: L10n.string("Sharing_sendToFriend_setupEmailMessage"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
            presenter.present(alert, animated: true)
            return
        }
        accountSetupPresenter.presentAccountSetup(from: presenter)
    }

    private static func presentError(_ error: Error, from presenter: UIViewController) {
        let alert = UIAlertController(
            title: L10n.string("Sharing_sendToFriend_sendErrorTitle"),
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
        presenter.present(alert, animated: true)
    }
}
