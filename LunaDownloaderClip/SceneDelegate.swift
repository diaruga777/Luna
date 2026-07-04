//
//  SceneDelegate.swift
//  LunaDownloaderClip
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let downloadViewController = ClipDownloadViewController()

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UINavigationController(rootViewController: downloadViewController)
        self.window = window
        window.makeKeyAndVisible()

        if let activity = connectionOptions.userActivities.first {
            handle(activity)
        } else if let context = connectionOptions.urlContexts.first {
            downloadViewController.handleLaunchURL(context.url)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        handle(userActivity)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        downloadViewController.handleLaunchURL(url)
    }

    private func handle(_ activity: NSUserActivity) {
        guard let url = activity.webpageURL else { return }
        downloadViewController.handleLaunchURL(url)
    }
}
