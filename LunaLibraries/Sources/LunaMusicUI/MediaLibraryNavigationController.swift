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
        let search = topViewController?.navigationItem.searchController
        let keepsSearchFocus = search?.searchBar.searchTextField.isFirstResponder == true
        let finish = { [weak self] in
            guard let self else { return }
            // Avoid a crossfade gap between the outgoing and incoming keyboard
            // owners. UIKit installs the new navigation search on the next turn.
            self.replaceStack(destination, animated: animated && !keepsSearchFocus) {
                self.topViewController?.loadViewIfNeeded()
                guard keepsSearchFocus,
                      let owner = self.topViewController,
                      let incomingSearch = owner.navigationItem.searchController as? LibrarySearchController else {
                    completion?(); return
                }
                self.view.layoutIfNeeded()
                DispatchQueue.main.async { [weak self, weak owner] in
                    guard let self, let owner, self.surface == destination,
                          self.topViewController === owner, owner.view.window != nil,
                          self.presentedViewController == nil else { completion?(); return }
                    incomingSearch.focusSearch()
                    completion?()
                }
            }
        }
        if !keepsSearchFocus { view.endEditing(true) }
        if let search, search.isActive {
            // Wait until UIKit finishes restoring the search owner's navigation
            // item before replacing the root, including for incoming deep links.
            let query = search.searchBar.text
            search.dismiss(animated: false) {
                search.isActive = false
                // UIKit clears the field when ending search presentation. A
                // surface switch should retain the query for the return trip.
                search.searchBar.text = query
                search.searchResultsUpdater?.updateSearchResults(for: search)
                finish()
            }
        } else {
            finish()
        }
    }

    private func replaceStack(_ destination: MediaPlaybackCoordinator.Surface, animated: Bool, completion: @escaping () -> Void) {
        guard surface != destination else { completion(); return }
        if surface == .music { musicStack = viewControllers }
        else { podcastStack = viewControllers }
        surface = destination
        UserDefaults.standard.set(destination == .podcasts, forKey: "LunaMusic.browsingPodcasts")
        let stack = destination == .music ? musicStack : podcastStack
        let root: UIViewController = destination == .music ? music : podcasts
        // Replacing the root avoids a misleading Back button between surfaces.
        let update = { self.setViewControllers(stack.isEmpty ? [root] : stack, animated: false) }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: view, duration: 0.25, options: [.transitionCrossDissolve, .allowAnimatedContent], animations: update, completion: { _ in completion() })
        } else { update(); completion() }
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

    public func openReader(saveID: UUID?) {
        route(to: .podcasts) {
            self.setViewControllers([self.podcasts, ReaderPodcastsViewController(saveID: saveID)], animated: false)
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
@MainActor final class LibrarySearchController: UISearchController, UISearchControllerDelegate {
    private var pendingSearchFocus = false
    init(placeholder: String, identifier: String, label: String) {
        super.init(searchResultsController: nil)
        delegate = self
        obscuresBackgroundDuringPresentation = false
        searchBar.placeholder = placeholder
        searchBar.searchTextField.font = .preferredFont(forTextStyle: .body)
        searchBar.searchTextField.accessibilityIdentifier = identifier
        searchBar.accessibilityLabel = label
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func focusSearch() {
        pendingSearchFocus = true
        isActive = true
        searchBar.becomeFirstResponder()
    }
    func didPresentSearchController(_ searchController: UISearchController) {
        // The incoming navigation search is not ready to receive keyboard focus
        // until UIKit has finished its presentation after the stack replacement.
        if pendingSearchFocus {
            searchBar.becomeFirstResponder()
            pendingSearchFocus = false
        }
    }
    func didDismissSearchController(_ searchController: UISearchController) {
        pendingSearchFocus = false
    }
    func install(on owner: UIViewController) {
        owner.navigationItem.searchController = self
        owner.navigationItem.preferredSearchBarPlacement = .stacked
        owner.navigationItem.hidesSearchBarWhenScrolling = false
        owner.definesPresentationContext = true
    }
}
