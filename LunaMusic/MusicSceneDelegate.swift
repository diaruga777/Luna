import UIKit
import LunaMusicCore
import LunaMusicUI
import LunaPodcastCore
import LunaVaultUI

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
        let window = UIWindow(windowScene: scene)
        window.tintColor = .systemPink
        window.rootViewController = MusicVaultWiring.launchController(makeContent: { [weak self] in
            let library = MusicLibraryViewController()
            self?.library = library
            return UINavigationController(rootViewController: library)
        }, onContinue: { [weak self] in self?.resumeLibrary() })
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "LunaMusic.browsingPodcasts") == nil {
            defaults.set(defaults.integer(forKey: "LunaMusic.browsingTab") == 1, forKey: "LunaMusic.browsingPodcasts")
        }
        self.window = window
        window.makeKeyAndVisible()
        routeObservers.append(NotificationCenter.default.addObserver(forName: .lunaPodcastOpenEpisode, object: nil, queue: .main) { [weak self] notification in
            guard let id = notification.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.openPodcastEpisode(id) }
        })
        if let id = MusicIntentRoute.pendingPodcastEpisodeID { openPodcastEpisode(id) }
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
        UserDefaults.standard.set(browsingPodcasts, forKey: "LunaMusic.browsingPodcasts")
        PodcastBackgroundServices.shared.background()
        MusicVaultWiring.background()
        enteredBackground = true
        activationWork?.cancel()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Permission dialogs and Control Center do not constitute a new foreground.
        guard enteredBackground || pendingRoute != nil else { return }
        PodcastBackgroundServices.shared.foreground()
        MusicVaultWiring.foreground()
        enteredBackground = false
        activationWork?.cancel()
        guard isShowingLibrary else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resumeLibrary()
        }
        activationWork = work
        DispatchQueue.main.async(execute: work)
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let url = contexts.map(\.url).first, let route = MusicLaunchRoute(url: url) else { return }
        capture(url)
        navigate(route)
    }

    private var isShowingLibrary: Bool {
        (window?.rootViewController as? LunaMacLaunchViewController)?.isShowingContent ?? true
    }
    private func resumeLibrary() {
        guard isShowingLibrary else { return }
        if let id = MusicIntentRoute.pendingPodcastEpisodeID { openPodcastEpisode(id); return }
        if UserDefaults.standard.bool(forKey: "LunaMusic.browsingPodcasts") { library?.showPodcasts(animated: false) }
        let route = pendingRoute; pendingRoute = nil
        if let route { apply(route) }
        else if !browsingPodcasts { library?.foregroundSearch() }
        Task { await MusicLibraryController.shared.reload() }
    }
    private var browsingPodcasts: Bool {
        library?.navigationController?.viewControllers.contains(where: { $0 is PodcastLibraryViewController }) == true
    }

    private func openPodcastEpisode(_ id: String) {
        guard isShowingLibrary else { MusicIntentRoute.pendingPodcastEpisodeID = id; return }
        activationWork?.cancel()
        library?.showPodcasts(animated: false).openEpisode(id)
        MusicIntentRoute.pendingPodcastEpisodeID = nil
    }

    private func capture(_ url: URL) {
        pendingRoute = MusicLaunchRoute(url: url)
        searchQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
    }

    private func navigate(_ route: MusicLaunchRoute) {
        activationWork?.cancel()
        if isShowingLibrary, window?.windowScene?.activationState == .foregroundActive {
            pendingRoute = nil
            apply(route)
        } else {
            pendingRoute = route
        }
    }

    private func apply(_ route: MusicLaunchRoute) {
        switch route {
        case .search: library?.foregroundSearch(query: searchQuery); searchQuery = ""
        case .queue:
            if MediaPlaybackCoordinator.shared.active == .podcasts { library?.showPodcasts(animated: false).showQueue() }
            else { library?.showQueue() }
        }
    }

    deinit {
        activationWork?.cancel()
        routeObservers.forEach(NotificationCenter.default.removeObserver)
    }
}
