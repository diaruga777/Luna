//
//  SceneDelegate.swift
//  Clip
//
//  Clip is a weblink reader: save links from Safari (via the bundled Safari
//  extension + action-button shortcut), then read them in a scrolling reader
//  or an RSVP speed reader. Articles can be shared with friends (CloudKit
//  messages) and sent to a Kindle.
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    /// A friend URL that arrived before onboarding finished; replayed once an
    /// identity exists.
    private var pendingFriendURL: URL?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)

        if KeychainIdentityStore.shared.loadIdentity() == nil {
            let onboarding = OnboardingViewController { [weak self] in
                self?.showMainUI()
                if let url = self?.pendingFriendURL {
                    self?.pendingFriendURL = nil
                    self?.handleFriendURL(url)
                }
            }
            window.rootViewController = onboarding
        } else {
            window.rootViewController = UINavigationController(
                rootViewController: ReadingListViewController())
        }
        self.window = window
        window.makeKeyAndVisible()

        if let url = connectionOptions.urlContexts.first?.url {
            handleFriendURL(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        handleFriendURL(url)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Items may have been added by the intent while we were backgrounded.
        NotificationCenter.default.post(name: .readingListChanged, object: nil)
        ReadingListIngestor.shared.ingestAllPending()
        Task { await SocialMessageCenter.shared.processInbox() }
    }

    private func showMainUI() {
        window?.rootViewController = UINavigationController(
            rootViewController: ReadingListViewController())
    }

    /// Parses a `clipreader://friend` URL and runs the confirm-add flow.
    private func handleFriendURL(_ url: URL) {
        guard let card = FriendLink.card(from: url) else { return }
        guard KeychainIdentityStore.shared.loadIdentity() != nil else {
            pendingFriendURL = url
            return
        }
        guard let presenter = window?.rootViewController else { return }
        FriendAddFlow.confirmAndAdd(card: card, from: topViewController(of: presenter))
    }

    private func topViewController(of root: UIViewController) -> UIViewController {
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
