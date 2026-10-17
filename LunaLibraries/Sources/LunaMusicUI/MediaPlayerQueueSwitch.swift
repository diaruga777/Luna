import UIKit
import Combine
import LunaMusicCore

/// Keeps the presented controls aligned with the active queue, including a
/// switch made by a headset, CarPlay or a shortcut while the player is open.
@MainActor final class MediaPlayerQueueSwitch {
    let button = UIButton(type: .system)
    private weak var owner: UIViewController?
    private let surface: MediaPlaybackCoordinator.Surface
    private let showsQueue: () -> Bool
    private var subscriptions = Set<AnyCancellable>()
    private var replacing = false
    private var lastActive = MediaPlaybackCoordinator.shared.active

    init(owner: UIViewController, surface: MediaPlaybackCoordinator.Surface, showsQueue: @escaping () -> Bool) {
        self.owner = owner; self.surface = surface; self.showsQueue = showsQueue
        var configuration = UIButton.Configuration.plain()
        configuration.title = surface == .music ? "Podcasts" : "Music"
        configuration.image = UIImage(systemName: "arrow.triangle.swap")
        configuration.imagePadding = 6
        button.configuration = configuration
        button.accessibilityLabel = surface == .music ? "Switch to Podcasts" : "Switch to Music"
        button.accessibilityIdentifier = "media.playback.switchQueue"
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if MediaPlaybackCoordinator.shared.active != self.surface {
                self.replacePlayer()
                return
            }
            Task {
                await MediaPlaybackCoordinator.shared.switchQueue()
                if let message = MediaPlaybackCoordinator.shared.errorMessage, let owner = self.owner {
                    let alert = UIAlertController(title: "Unable to Switch Queue", message: message, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default)); owner.present(alert, animated: true)
                }
            }
        }, for: .touchUpInside)
        let coordinator = MediaPlaybackCoordinator.shared
        coordinator.$active.combineLatest(coordinator.$switching).sink { [weak self] _, _ in
            // Read after @Published has applied both values.
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &subscriptions)
        for name in [Notification.Name.lunaMusicPlaybackChanged, .lunaPodcastPlaybackChanged] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }.store(in: &subscriptions)
        }
        refresh()
    }

    private func refresh() {
        let coordinator = MediaPlaybackCoordinator.shared
        button.isEnabled = (coordinator.active != surface || coordinator.canSwitch) && !coordinator.switching
        button.accessibilityHint = coordinator.active != surface ? "Opens the active queue" :
            coordinator.canSwitch ? "Resumes the other queue at its saved position" : "Play an item in the other queue first"
        let changed = coordinator.active != lastActive
        // Keep the change pending while UIKit is still presenting the player.
        // Opening an inactive queue deliberately does not count as a change.
        guard changed, !coordinator.switching else { return }
        if coordinator.active == surface || replacePlayer() { lastActive = coordinator.active }
    }

    @discardableResult private func replacePlayer() -> Bool {
        guard !replacing, let owner, owner.viewIfLoaded?.window != nil else { return false }
        if let navigation = owner.navigationController, navigation.topViewController !== owner { return false }
        let container = owner.navigationController ?? owner
        guard !container.isBeingDismissed, let presenter = container.presentingViewController else { return false }
        replacing = true
        let queue = showsQueue()
        container.dismiss(animated: false) {
            let destination: UIViewController
            if MediaPlaybackCoordinator.shared.active == .podcasts {
                destination = UINavigationController(rootViewController: PodcastPlayerViewController(showQueue: queue))
            } else { destination = MusicPlayerViewController(showQueue: queue) }
            destination.modalPresentationStyle = .fullScreen
            presenter.present(destination, animated: false)
        }
        return true
    }
}
