//
//  AppDelegate.swift
//  Clip
//

import Photos
import UIKit
import UserNotifications
#if !targetEnvironment(simulator)
import MLX
#endif

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Cap MLX's reusable GPU buffer cache process-wide (set once here rather than
        // in every engine init) so freed buffers return to the OS and peak stays low.
        // Device-only: MLX initializes Metal eagerly here and aborts on the Simulator,
        // which has no MLX-compatible GPU (the VLM is device-only regardless).
        #if !targetEnvironment(simulator)
        MLX.GPU.set(cacheLimit: 64 * 1024 * 1024)
        #endif
        // Request notification permission up front so the locked-capture extension can
        // post the pocket-trigger notification (an extension can't show the prompt).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Proactively react to new camera-roll photos in the background: enable the
        // PhotoKit resource-upload extension (iOS 26.1+) so the system wakes us when
        // photos are added. Best-effort — only with full access; the foreground
        // observer covers the app-open case regardless.
        enableBackgroundPhotoScanIfPossible()
        return true
    }

    private func enableBackgroundPhotoScanIfPossible() {
        guard #available(iOS 26.1, *) else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        do {
            try PHPhotoLibrary.shared().setUploadJobExtensionEnabled(true)
        } catch {
            print("[info] background photo scan not enabled: \(error)")
        }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(
            name: connectingSceneSession.configuration.name,
            sessionRole: connectingSceneSession.role
        )
        config.delegateClass = SceneDelegate.self
        return config
    }
}
