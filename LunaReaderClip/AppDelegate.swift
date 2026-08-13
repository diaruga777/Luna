//
//  AppDelegate.swift
//  LunaReaderClip
//

import LunaReaderUI
import LunaArticleIngest
import LunaIngest
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // The clip reads articles, so it installs the article kind pack. This
        // is the same call every article surface makes, so the clip cannot
        // drift out of sync with them. See `ArticleKindComposition`.
        ArticleKindComposition.install()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
