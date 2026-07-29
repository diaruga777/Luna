//
//  AppDelegate.swift
//  LunaReaderClip
//

import LunaArticleIngest
import LunaIngest
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // The clip reads articles, so it registers the article-kind pipeline
        // processor (same composition contract as the apps' KindWiring).
        IngestKindProcessors.article = ArticleIngestProcessor()
        // Article-kind processing includes reading a long-form X post / self-thread
        // (claudedocs/x-posts.md) — required on every article-handling surface.
        IngestKindProcessors.socialText = XPostIngestProcessor()
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
