import LunaKeyboardCore
import LunaKeyboardUI
import LunaStorage
import UIKit
import UniformTypeIdentifiers

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication, configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Keyboard", sessionRole: session.role)
    configuration.delegateClass = KeyboardSceneDelegate.self
    return configuration
  }
}

final class KeyboardSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    self.window = window
    window.overrideUserInterfaceStyle = .dark
    window.tintColor = UIColor(red: 0.66, green: 0.60, blue: 1, alpha: 1)
    let nav = UINavigationController(rootViewController: KeyboardHomeController())
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--keyboard-tryout") {
        nav.setViewControllers(
          [KeyboardHomeController(), KeyboardTryoutController()], animated: false)
      }
    #endif
    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = .black
    nav.navigationBar.standardAppearance = appearance
    nav.navigationBar.scrollEdgeAppearance = appearance
    nav.navigationBar.prefersLargeTitles = true
    window.rootViewController = nav
    window.makeKeyAndVisible()
    try? KeyboardStore().reapAbandonedMedia()
  }
  func sceneDidEnterBackground(_ scene: UIScene) { SavesStore.shared.reapPendingDeletes() }
}
