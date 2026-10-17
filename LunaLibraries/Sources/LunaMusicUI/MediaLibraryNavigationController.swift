import UIKit
import LunaMusicCore

/// Browsing is independent of the active audio queue. Each surface keeps its
/// navigation stack, including its search query and scroll position.
@MainActor public final class MediaLibraryNavigationController: UINavigationController {
    public let music = MusicLibraryViewController()
    public let podcasts = PodcastLibraryViewController()
    public private(set) var surface: MediaPlaybackCoordinator.Surface = .music
    private var musicStack: [UIViewController] = []
    private var podcastStack: [UIViewController] = []

    public init() { super.init(rootViewController: music) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func select(_ destination: MediaPlaybackCoordinator.Surface, animated: Bool = true, completion: (() -> Void)? = nil) {
        guard surface != destination else { completion?(); return }
        music.cancelPendingSearchFocus()
        view.endEditing(true)
        if let search = topViewController?.navigationItem.searchController, search.isActive {
            // Wait until UIKit finishes restoring the search owner's navigation
            // item before replacing the root, including for incoming deep links.
            let query = search.searchBar.text
            search.dismiss(animated: false) { [weak self] in
                search.isActive = false
                self?.replaceStack(destination, animated: animated)
                // UIKit clears the field when ending search presentation. A
                // surface switch should retain the query for the return trip.
                search.searchBar.text = query
                search.searchResultsUpdater?.updateSearchResults(for: search)
                completion?()
            }
        } else {
            replaceStack(destination, animated: animated)
            completion?()
        }
    }

    private func replaceStack(_ destination: MediaPlaybackCoordinator.Surface, animated: Bool) {
        guard surface != destination else { return }
        if surface == .music { musicStack = viewControllers }
        else { podcastStack = viewControllers }
        surface = destination
        UserDefaults.standard.set(destination == .podcasts, forKey: "LunaMusic.browsingPodcasts")
        let stack = destination == .music ? musicStack : podcastStack
        let root: UIViewController = destination == .music ? music : podcasts
        // Replacing the root avoids a misleading Back button between surfaces.
        let update = { self.setViewControllers(stack.isEmpty ? [root] : stack, animated: false) }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: view, duration: 0.25, options: [.transitionCrossDissolve, .allowAnimatedContent], animations: update)
        } else { update() }
    }

    public func showPodcasts(animated: Bool = true) {
        select(.podcasts, animated: animated)
    }

    public func foregroundSearch(query: String = "") {
        if surface == .music { music.foregroundSearch(query: query) }
        else { route(to: .music) { self.music.foregroundSearch(query: query) } }
    }

    public func showMusicQueue() {
        route(to: .music) {
            let player = MusicPlayerViewController(showQueue: true)
            player.modalPresentationStyle = .fullScreen
            self.present(player, animated: true)
        }
    }

    public func showPodcastQueue() {
        route(to: .podcasts) {
            let player = UINavigationController(rootViewController: PodcastPlayerViewController(showQueue: true))
            player.modalPresentationStyle = .fullScreen
            self.present(player, animated: true)
        }
    }

    public func openPodcastEpisode(_ id: String) {
        route(to: .podcasts) { self.podcasts.openEpisode(id) }
    }

    private func route(to destination: MediaPlaybackCoordinator.Surface, action: @escaping () -> Void) {
        music.cancelPendingSearchFocus()
        view.endEditing(true)
        let apply = {
            self.topViewController?.navigationItem.searchController?.isActive = false
            self.select(destination, animated: false, completion: action)
        }
        if presentedViewController != nil { dismiss(animated: false, completion: apply) }
        else { apply() }
    }

}

/// Both libraries use the same native, always-visible navigation search.
@MainActor final class LibrarySearchController: UISearchController {
    init(placeholder: String, identifier: String, label: String) {
        super.init(searchResultsController: nil)
        obscuresBackgroundDuringPresentation = false
        searchBar.placeholder = placeholder
        searchBar.searchTextField.font = .preferredFont(forTextStyle: .body)
        searchBar.searchTextField.accessibilityIdentifier = identifier
        searchBar.accessibilityLabel = label
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func install(on owner: UIViewController) {
        owner.navigationItem.searchController = self
        owner.navigationItem.preferredSearchBarPlacement = .stacked
        owner.navigationItem.hidesSearchBarWhenScrolling = false
        owner.definesPresentationContext = true
    }
}
