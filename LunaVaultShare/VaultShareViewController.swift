import UIKit

/// Direct sharing is not wired to the active Mac-backed store yet. Never
/// report a successful save when the extension has not persisted the item.
final class VaultShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        var content = UIContentUnavailableConfiguration.empty()
        content.image = UIImage(systemName: "square.and.arrow.down")
        content.text = "Import in Vault"
        content.secondaryText = "To add this file, open Luna Vault and tap + to choose it from Files. Direct sharing to Vault isn’t available yet."
        content.button = .filled()
        content.button.title = "Close"
        content.button.cornerStyle = .capsule
        content.buttonProperties.primaryAction = UIAction { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        contentUnavailableConfiguration = content
    }
}
