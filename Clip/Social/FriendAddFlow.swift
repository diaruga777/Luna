//
//  FriendAddFlow.swift
//  Clip
//

import UIKit

/// The shared confirm-and-add flow used by tapped links, the in-app scanner,
/// and the system camera: verify iCloud, confirm with the user, add locally,
/// then message the new friend so they add us back.
enum FriendAddFlow {

    /// Presents "Add <username>?" and on confirmation stores the friend and
    /// sends the bi-directional friendAdd message.
    static func confirmAndAdd(card: IdentityCard, from presenter: UIViewController) {
        guard let identity = KeychainIdentityStore.shared.loadIdentity() else { return }
        guard card.uuid != identity.uuid || isSelfAddAllowed else {
            // Adding yourself is only useful for testing; allowed in DEBUG.
            return
        }

        var detailLines = ["Add \(card.username) as a friend?"]
        if let email = card.email { detailLines.append(email) }
        if let phone = card.phone { detailLines.append(phone) }

        let alert = UIAlertController(
            title: "Add Friend",
            message: detailLines.joined(separator: "\n"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { _ in
            Task { @MainActor in
                guard await ICloudGate.requireICloud(presenting: presenter) else { return }
                FriendsStore.shared.add(card)
                await SocialMessageCenter.shared.sendFriendAdd(to: card)
                Toast.show("Added \(card.username)", from: presenter)
            }
        })
        presenter.present(alert, animated: true)
    }

    /// Self-adds are permitted in debug builds for single-account testing.
    private static var isSelfAddAllowed: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

/// Confirms to the user that iCloud is required for friend sharing.
enum ICloudGate {

    /// Returns true when messaging is available; otherwise presents the
    /// "iCloud required" alert (with an Open Settings shortcut) and returns false.
    @MainActor
    static func requireICloud(presenting presenter: UIViewController) async -> Bool {
        switch await SocialMessageCenter.shared.availability() {
        case .available:
            return true
        case .unavailable(let reason):
            let alert = UIAlertController(
                title: "iCloud Required",
                message: "Sharing with friends requires iCloud. \(reason)",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            presenter.present(alert, animated: true)
            return false
        }
    }
}
