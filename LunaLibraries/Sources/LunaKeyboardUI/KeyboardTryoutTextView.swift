import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A real media-capable message editor for exercising the keyboard's copy/paste flow.
public final class KeyboardTryoutTextView: UITextView {
  private var mediaViews: [Int: (KeyboardMediaAttachment, KeyboardMediaPreview)] = [:]
  private var layingOutMedia = false

  public override init(frame: CGRect, textContainer: NSTextContainer?) {
    // UIKit owns the TextKit 2 stack and its viewport attachment lifecycle.
    super.init(frame: frame, textContainer: textContainer)
    allowsEditingTextAttributes = true
    pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.gif.identifier, UTType.image.identifier, UTType.plainText.identifier])
  }
  public override func layoutSubviews() {
    super.layoutSubviews()
    guard !layingOutMedia, window != nil else { return }
    layingOutMedia = true
    defer { layingOutMedia = false }
    var visible = Set<Int>()
    // UITextView does not consistently mount view-backed attachments in its
    // editable viewport. Use its public text geometry to host bounded previews.
    attributedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedText.length)) { value, range, stop in
      guard let attachment = value as? KeyboardMediaAttachment,
        let start = position(from: beginningOfDocument, offset: range.location),
        let end = position(from: start, offset: 1), let textRange = textRange(from: start, to: end) else { return }
      let rect = firstRect(for: textRange)
      let frame = CGRect(x: rect.minX, y: rect.maxY - attachment.bounds.height,
                         width: attachment.bounds.width, height: attachment.bounds.height)
      guard frame.intersects(bounds) else { return }
      visible.insert(range.location)
      if mediaViews[range.location]?.0 !== attachment {
        mediaViews[range.location]?.1.reset()
        mediaViews[range.location]?.1.removeFromSuperview()
        let preview = KeyboardMediaPreview(frame: frame)
        addSubview(preview)
        if let data = attachment.contents { preview.load(data: data) }
        mediaViews[range.location] = (attachment, preview)
      }
      mediaViews[range.location]?.1.frame = frame
      if visible.count >= 8 { stop.pointee = true }
    }
    for key in Array(mediaViews.keys) where !visible.contains(key) {
      mediaViews.removeValue(forKey: key).map { $0.1.reset(); $0.1.removeFromSuperview() }
    }
  }
  public override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      mediaViews.values.forEach { $0.1.reset(); $0.1.removeFromSuperview() }
      mediaViews.removeAll()
    } else { setNeedsLayout() }
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
      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) > 0 else { return }
    let attachment = KeyboardMediaAttachment(data: data, ofType: CGImageSourceGetType(source) as String?)
    attachment.allowsTextAttachmentView = false
    // Setting attachment.image would discard contents/fileType and disable the animated view.
    attachment.bounds = CGRect(x: 0, y: 0, width: 80, height: 80)
    let text = NSMutableAttributedString(attributedString: attributedText)
    let insertion = NSMutableAttributedString(attachment: attachment)
    insertion.append(NSAttributedString(string: " ", attributes: typingAttributes))
    let end = selectedRange.location + insertion.length
    text.replaceCharacters(in: selectedRange, with: insertion)
    attributedText = text
    selectedRange = NSRange(location: end, length: 0)
    setNeedsLayout()
    delegate?.textViewDidChange?(self)
  }
}

private final class KeyboardMediaAttachment: NSTextAttachment {
  // Reserve inline geometry without asking UIKit to decode a full-size still.
  private static let placeholder = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
  override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?) -> UIImage? {
    Self.placeholder
  }
}
