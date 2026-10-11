import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A real media-capable message editor for exercising the keyboard's copy/paste flow.
public final class KeyboardTryoutTextView: UITextView {
  public override init(frame: CGRect, textContainer: NSTextContainer?) {
    // View-backed GIF attachments require TextKit 2, including in the tryout host.
    let container: NSTextContainer
    if let textContainer { container = textContainer }
    else {
      let content = NSTextContentStorage()
      let layout = NSTextLayoutManager()
      container = NSTextContainer(size: .zero)
      content.addTextLayoutManager(layout)
      layout.textContainer = container
    }
    super.init(frame: frame, textContainer: container)
    pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.gif.identifier, UTType.image.identifier, UTType.plainText.identifier])
  }
  public required init?(coder: NSCoder) { fatalError("init(coder:)") }
  public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(paste(_:)), UIPasteboard.general.hasImages || UIPasteboard.general.contains(pasteboardTypes: [UTType.gif.identifier]) { return true }
    return super.canPerformAction(action, withSender: sender)
  }
  public override func paste(_ sender: Any?) {
    if let data = UIPasteboard.general.data(forPasteboardType: UTType.gif.identifier) ?? UIPasteboard.general.image?.pngData() {
      insertMedia(data)
    } else { super.paste(sender) }
  }
  public override func paste(itemProviders: [NSItemProvider]) {
    guard let provider = itemProviders.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) else {
      super.paste(itemProviders: itemProviders); return
    }
    let selection = selectedRange
    let original = attributedText.copy() as! NSAttributedString
    let type = provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) ? UTType.gif.identifier : UTType.image.identifier
    provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, _ in
      DispatchQueue.main.async {
        guard let self, let data, self.selectedRange == selection, self.attributedText.isEqual(to: original) else { return }
        self.insertMedia(data)
      }
    }
  }
  func insertMedia(_ data: Data) {
    guard data.count <= 8 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240] as CFDictionary) != nil else { return }
    let attachment = KeyboardMediaAttachment(data: data, ofType: CGImageSourceGetType(source) as String?)
    attachment.allowsTextAttachmentView = true
    // Setting attachment.image would discard contents/fileType and disable the animated view.
    attachment.bounds = CGRect(x: 0, y: 0, width: 80, height: 80)
    let text = NSMutableAttributedString(attributedString: attributedText)
    let insertion = NSMutableAttributedString(attachment: attachment)
    insertion.append(NSAttributedString(string: " ", attributes: typingAttributes))
    let end = selectedRange.location + insertion.length
    text.replaceCharacters(in: selectedRange, with: insertion)
    attributedText = text
    selectedRange = NSRange(location: end, length: 0)
    delegate?.textViewDidChange?(self)
  }
}

private final class KeyboardMediaAttachment: NSTextAttachment {
  override var usesTextAttachmentView: Bool { true }
  override func viewProvider(for parentView: UIView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
    KeyboardAttachmentViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
  }
}

private final class KeyboardAttachmentViewProvider: NSTextAttachmentViewProvider {
  override func loadView() {
    let preview = KeyboardMediaPreview()
    if let data = textAttachment?.contents { preview.load(data: data) }
    view = preview
  }
}
