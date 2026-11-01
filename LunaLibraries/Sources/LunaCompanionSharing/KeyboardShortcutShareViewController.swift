import UIKit
import ImageIO
import LunaStorage
import UniformTypeIdentifiers

open class KeyboardShortcutShareViewController: CompanionShareViewController {
    private var keyword: UITextField!
    private var text: UITextView!
    private var imageURL: URL?
    private var save: UIButton!
    open override func viewDidLoad() {
        super.viewDidLoad()
        heading("Save Keyboard Shortcut")
        keyword = field("Keyword"); keyword.autocapitalizationType = .none; keyword.autocorrectionType = .no
        text = UITextView(); text.font = .preferredFont(forTextStyle: .body)
        text.heightAnchor.constraint(equalToConstant: 130).isActive = true; stack.addArrangedSubview(text)
        save = button("Save") { [weak self] in self?.saveShortcut() }; save.isEnabled = false
        stack.addArrangedSubview(status); cancelButton()
        Task { @MainActor in
            do {
                let providers = SharedInput.providers(in: extensionContext)
                if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
                    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        imageURL = try await SharedInput.file(provider, conformingTo: .image)
                    } else if let url = try await SharedInput.item(provider, type: UTType.fileURL.identifier) as? URL,
                              UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                        imageURL = try await SharedInput.file(provider, conformingTo: .image)
                    }
                    guard let imageURL else {
                        text.text = try await SharedInput.text(in: extensionContext)
                        save.isEnabled = true; return
                    }
                    let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil)
                    let thumbnail = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 600,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ] as CFDictionary) }
                    let preview = UIImageView(image: thumbnail.map(UIImage.init(cgImage:))); preview.contentMode = .scaleAspectFit
                    preview.heightAnchor.constraint(equalToConstant: 140).isActive = true
                    stack.insertArrangedSubview(preview, at: 1); text.isHidden = true
                } else { text.text = try await SharedInput.text(in: extensionContext) }
                save.isEnabled = true
            } catch { status.text = error.localizedDescription }
        }
    }
    private func saveShortcut() {
        let word = keyword.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !word.isEmpty else { status.text = "Enter a keyword."; keyword.becomeFirstResponder(); return }
        performSave { [self] in
            let kind = imageURL.map { $0.pathExtension.lowercased() == "gif" ? "gif" : "image" } ?? "text"
            try KeyboardStore().save(KeyboardShortcut(keywords: [word], text: text.text ?? "", kind: kind), importing: imageURL)
        }
    }
    deinit { if let imageURL { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) } }
}
