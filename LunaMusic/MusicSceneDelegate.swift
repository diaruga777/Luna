import UIKit
import LunaMusicCore
import LunaMusicUI

/// External navigation wins over the ordinary foreground search, including
/// URLs delivered after sceneDidBecomeActive during a warm launch.
final class MusicSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var library: MusicLibraryViewController?
    private var pendingRoute: MusicLaunchRoute?
    private var searchQuery = ""
    private var activationWork: DispatchWorkItem?
    private var routeObservers: [NSObjectProtocol] = []
    private var enteredBackground = true

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let library = MusicLibraryViewController()
        self.library = library
        let window = UIWindow(windowScene: scene)
        window.tintColor = .systemPink
        window.rootViewController = UINavigationController(rootViewController: library)
        self.window = window
        window.makeKeyAndVisible()
        let initialURL = options.urlContexts.map(\.url).first ?? MusicIntentRoute.pendingURL
        MusicIntentRoute.pendingURL = nil
        if let initialURL { capture(initialURL) }
        for (name, route) in [(Notification.Name.lunaMusicOpenQueue, MusicLaunchRoute.queue), (.lunaMusicOpenSearch, .search)] {
            routeObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let url = notification.userInfo?["url"] as? URL
                Task { @MainActor in
                    MusicIntentRoute.pendingURL = nil
                    if let url { self?.capture(url) }
                    self?.navigate(route)
                }
            })
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        enteredBackground = true
        activationWork?.cancel()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Permission dialogs and Control Center do not constitute a new foreground.
        guard enteredBackground || pendingRoute != nil else { return }
        enteredBackground = false
        activationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let route = self.pendingRoute ?? .search
            self.pendingRoute = nil
            self.apply(route)
        }
        activationWork = work
        DispatchQueue.main.async(execute: work)
        Task { await MusicLibraryController.shared.reload() }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let url = contexts.map(\.url).first, let route = MusicLaunchRoute(url: url) else { return }
        capture(url)
        navigate(route)
    }

    private func capture(_ url: URL) {
        pendingRoute = MusicLaunchRoute(url: url)
        searchQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
    }

    private func navigate(_ route: MusicLaunchRoute) {
        activationWork?.cancel()
        if window?.windowScene?.activationState == .foregroundActive {
            pendingRoute = nil
            apply(route)
        } else {
            pendingRoute = route
        }
    }

    private func apply(_ route: MusicLaunchRoute) {
        switch route {
        case .search: library?.foregroundSearch(query: searchQuery); searchQuery = ""
        case .queue: library?.showQueue()
        }
    }

    deinit {
        activationWork?.cancel()
        routeObservers.forEach(NotificationCenter.default.removeObserver)
    }
}
