import UIKit
import LunaDesignSystem

/// Where Settings is opened from: the sidebar's gear button and `⌘,` both
/// call this rather than constructing the screen themselves, so the two
/// stay in agreement about how it is presented.
extension WriterSettingsViewController {
    /// A form sheet on a wide container, where there is room beside the
    /// editor to show it modally without covering the whole window; a push
    /// on a compact one, where a form sheet would already fill the screen.
    public static func present(from presenter: UIViewController, environment: LibraryEnvironment) {
        let settings = WriterSettingsViewController(environment: environment)
        if LunaLayout.isWide(containerWidth: presenter.view.bounds.width) {
            let navigationController = UINavigationController(rootViewController: settings)
            navigationController.modalPresentationStyle = .formSheet
            presenter.present(navigationController, animated: true)
        } else if let hostNavigationController = presenter.navigationController {
            hostNavigationController.pushViewController(settings, animated: true)
        } else {
            presenter.present(UINavigationController(rootViewController: settings), animated: true)
        }
    }
}
