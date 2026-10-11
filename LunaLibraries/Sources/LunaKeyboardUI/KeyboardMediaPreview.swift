import ImageIO
import UIKit

/// Decodes only the current, downsampled GIF frame. Never retains a GIF's frame array.
final class KeyboardMediaPreview: UIView {
  private let imageView = UIImageView()
  private let label = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var task: Task<Void, Never>?
  private var source: CGImageSource?
  private var frameIndex = 0
  private var timer: Timer?
  private var token = UUID()
  var message: String? { didSet { label.text = message; label.isHidden = message == nil } }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    layer.cornerRadius = 8
    clipsToBounds = true
    imageView.contentMode = .scaleAspectFit
    label.textAlignment = .center
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: 20)
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.6
    label.textColor = .white
    [imageView, label, spinner].forEach(addSubview)
    isUserInteractionEnabled = false
  }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  deinit { task?.cancel(); timer?.invalidate() }
  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = bounds.insetBy(dx: 2, dy: 2)
    label.frame = bounds.insetBy(dx: 8, dy: 6)
    spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
  }
  func reset() {
    token = UUID()
    task?.cancel(); task = nil
    timer?.invalidate(); timer = nil
    source = nil; frameIndex = 0
    imageView.image = nil
    message = nil
    spinner.stopAnimating()
  }
  func load(_ url: URL?, text: String? = nil) {
    reset()
    message = text
    guard let url else { return }
    spinner.startAnimating()
    let token = self.token
    task = Task { [weak self] in
      do {
        let local = url.isFileURL ? url : try await KeyboardMediaSearch.download(url, maxBytes: 2 * 1024 * 1024)
        defer { if !url.isFileURL { try? FileManager.default.removeItem(at: local) } }
        // Data keeps the compressed source alive after the temporary download is removed.
        let data = try Data(contentsOf: local, options: .mappedIfSafe)
        guard data.count <= 8 * 1024 * 1024, !Task.isCancelled, let self, self.token == token else { return }
        self.source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        self.spinner.stopAnimating()
        self.displayFrame()
      } catch {
        guard !Task.isCancelled, let self, self.token == token else { return }
        self.spinner.stopAnimating()
        self.message = "Preview unavailable"
      }
    }
  }
  private func displayFrame() {
    guard let source, CGImageSourceGetCount(source) > 0 else { return }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: 240,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    if let cg = CGImageSourceCreateThumbnailAtIndex(source, frameIndex, options as CFDictionary) {
      imageView.image = UIImage(cgImage: cg)
    }
    guard window != nil, !UIAccessibility.isReduceMotionEnabled, CGImageSourceGetCount(source) > 1 else { return }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any]
    let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
      ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
    timer = Timer.scheduledTimer(withTimeInterval: max(0.06, delay), repeats: false) { [weak self] _ in
      guard let self, let source = self.source else { return }
      self.frameIndex = (self.frameIndex + 1) % CGImageSourceGetCount(source)
      self.displayFrame()
    }
  }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    timer?.invalidate(); timer = nil
    if window != nil { displayFrame() }
  }
}

final class KeyboardMediaCell: UICollectionViewCell {
  let preview = KeyboardMediaPreview()
  private let feedback = UILabel()
  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.addSubview(preview)
    contentView.addSubview(feedback)
    feedback.font = .systemFont(ofSize: 15, weight: .semibold)
    feedback.textAlignment = .center
    feedback.numberOfLines = 0
    feedback.textColor = .white
    feedback.backgroundColor = UIColor.black.withAlphaComponent(0.7)
    feedback.layer.cornerRadius = 8
    feedback.clipsToBounds = true
    feedback.isHidden = true
    isAccessibilityElement = true
    accessibilityTraits = .button
  }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  override func layoutSubviews() {
    super.layoutSubviews()
    preview.frame = bounds.insetBy(dx: 2, dy: 2)
    feedback.frame = bounds.insetBy(dx: 2, dy: 2)
  }
  override func prepareForReuse() { super.prepareForReuse(); preview.reset(); showFeedback(nil) }
  func showFeedback(_ text: String?) { feedback.text = text; feedback.isHidden = text == nil }
}
