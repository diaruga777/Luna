import UIKit

open class WriterShareViewController: CompanionShareViewController {
    private let mode = UISegmentedControl(items: ["Note", "New Document"])
    private var titleField: UITextField!
    private let text = UITextView()
    private var save: UIButton!
    open override func viewDidLoad() {
        super.viewDidLoad(); heading("Save to Luna Writer")
        mode.selectedSegmentIndex = 0; stack.addArrangedSubview(mode)
        mode.addAction(UIAction { [weak self] _ in self?.updateMode() }, for: .valueChanged)
        titleField = field("Title"); titleField.isHidden = true
        text.font = .preferredFont(forTextStyle: .body); text.accessibilityLabel = "Text"
        text.heightAnchor.constraint(equalToConstant: 180).isActive = true; stack.addArrangedSubview(text)
        save = button("Save Note & Close") { [weak self] in self?.saveText() }; save.isEnabled = false
        stack.addArrangedSubview(status); cancelButton()
        Task { @MainActor in
            do { text.text = try await SharedInput.text(in: extensionContext); save.isEnabled = true }
            catch { status.text = error.localizedDescription }
        }
    }
    private func updateMode() {
        titleField.isHidden = mode.selectedSegmentIndex == 0
        save.configuration?.title = mode.selectedSegmentIndex == 0 ? "Save Note & Close" : "Save Document & Close"
    }
    private func saveText() {
        let content = text.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else { status.text = "Enter some text."; return }
        let capture = CompanionShareCapture(kind: mode.selectedSegmentIndex == 0 ? .note : .document,
                                            text: content, title: titleField.text ?? "")
        performSave { try CompanionShareInbox.production("writer").save(capture) }
    }
}
