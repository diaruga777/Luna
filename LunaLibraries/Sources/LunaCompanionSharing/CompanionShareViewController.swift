@_exported import LunaCompanionShareCore
import UIKit

open class CompanionShareViewController: UIViewController {
    public let stack = UIStackView()
    public let status = UILabel()
    public private(set) var busy = false
    public var onComplete: (() -> Void)?
    public override init(nibName: String? = nil, bundle: Bundle? = nil) { super.init(nibName: nibName, bundle: bundle) }
    public required init?(coder: NSCoder) { super.init(coder: coder) }
    open override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 420, height: 540)
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        status.numberOfLines = 0; status.textColor = .secondaryLabel
    }
    public func heading(_ text: String) {
        let label = UILabel(); label.text = text; label.font = .preferredFont(forTextStyle: .title2)
        label.adjustsFontForContentSizeCategory = true; stack.addArrangedSubview(label)
    }
    public func field(_ placeholder: String) -> UITextField {
        let field = UITextField(); field.placeholder = placeholder; field.borderStyle = .roundedRect
        field.accessibilityLabel = placeholder; field.clearButtonMode = .whileEditing
        stack.addArrangedSubview(field); return field
    }
    @discardableResult public func button(_ title: String, filled: Bool = true, action: @escaping () -> Void) -> UIButton {
        var config: UIButton.Configuration = filled ? .filled() : .plain(); config.title = title
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        stack.addArrangedSubview(button); return button
    }
    public func cancelButton() {
        button("Cancel", filled: false) { [weak self] in
            guard let self, !busy else { return }
            if let onComplete { onComplete() }
            else { extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) }
        }
    }
    public func finish() {
        if let onComplete { onComplete() }
        else { extensionContext?.completeRequest(returningItems: nil) }
    }
    public func performSave(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true
        view.endEditing(true); view.isUserInteractionEnabled = false; isModalInPresentation = true
        status.text = "Saving…"
        Task { @MainActor in
            do { try await operation(); finish() }
            catch { status.text = error.localizedDescription }
            busy = false; view.isUserInteractionEnabled = true; isModalInPresentation = false
        }
    }
}
