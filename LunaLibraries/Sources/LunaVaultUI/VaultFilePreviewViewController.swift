import QuickLook
import UIKit

/// The system file/image viewer, with UIKit owning the safe-area navigation
/// chrome. Keep Quick Look as the navigation root so its toolbar and zooming
/// behave as they do in Files, rather than embedding its view in a plain host.
public final class VaultFilePreviewViewController: UINavigationController, QLPreviewControllerDataSource {
    private let fileURL: URL
    private var onDismiss: (() -> Void)?

    public init(url: URL, onDismiss: (() -> Void)? = nil) {
        fileURL = url
        self.onDismiss = onDismiss
        let preview = QLPreviewController()
        super.init(rootViewController: preview)
        preview.dataSource = self
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(closePreview))
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        let completion = onDismiss
        onDismiss = nil
        completion?()
    }

    @objc private func closePreview() { dismiss(animated: true) }

    public func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        fileURL as NSURL
    }
}
