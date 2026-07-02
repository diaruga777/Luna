//
//  SendToFriendSheet.swift
//  LunaSocialUI
//

import LunaSocial
import LunaReadingList
import LunaModels
import LunaDesignSystem
import UIKit

/// The shared "share this" entry point used by the reading list and the reader:
/// pick recipients and send a Luna email, or fall back to the system share sheet
/// with the plain URL.
public enum SendToFriendSheet {

    /// Injected by the app so the sheet can launch the email-account login flow
    /// when no account is configured yet.
    public static var accountSetupLauncher: ((UIViewController) -> Void)?

    /// Presents the recipient picker for a reading-list item (preferred — sends
    /// the item's rich content), or a bare URL when no item is available.
    public static func present(
        from presenter: UIViewController,
        item: ReadingListItem? = nil,
        urlString: String,
        title: String?
    ) {
        guard EmailShareCenter.shared.isConfigured else {
            promptAccountSetup(from: presenter)
            return
        }
        let picker = RecipientPickerViewController { emails in
            guard !emails.isEmpty else { return }
            deliver(item: item, urlString: urlString, title: title, to: emails, from: presenter)
        }
        let nav = UINavigationController(rootViewController: picker)
        presenter.present(nav, animated: true)
    }

    /// Shares the plain URL via the system share sheet (no Luna framing).
    public static func shareLink(urlString: String, from presenter: UIViewController, sourceView: UIView?) {
        let shared: Any = URL(string: urlString) ?? urlString
        let activity = UIActivityViewController(activityItems: [shared], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = sourceView ?? presenter.view
        presenter.present(activity, animated: true)
    }

    // MARK: - Delivery

    private static func deliver(
        item: ReadingListItem?, urlString: String, title: String?,
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

    private static func promptAccountSetup(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "Set up email first",
            message: "Connect your email account to send articles to friends.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        if let launcher = accountSetupLauncher {
            alert.addAction(UIAlertAction(title: "Set Up", style: .default) { _ in
                launcher(presenter)
            })
        }
        presenter.present(alert, animated: true)
    }

    private static func presentError(_ error: Error, from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "Couldn't send",
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }
}
