import ImageIO
import UIKit

/// Decodes only the current, downsampled GIF frame. Never retains a GIF's frame array.
final class KeyboardMediaPreview: UIView {
  private let imageView = UIImageView()
  private let label = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var task: Task<Void, Never>?
  private var source: CGImageSource?
  private var decodeTask: Task<Void, Never>?
  private var animating = true
  private var isLoaded = false
  private var loadedURL: URL?
  private var loadedText: String?
  private var frameIndex = 0
  private(set) var displayedFrameCount = 0
  private var timer: Timer?
  private var token = UUID()
  var isStatus = false {
    didSet {
      label.font = .systemFont(ofSize: isStatus ? 14 : (message?.count ?? 0) <= 3 ? 36 : 20, weight: isStatus ? .medium : .regular)
      label.numberOfLines = isStatus || message?.contains("\n") == true ? 0 : 1
    }
  }
  var message: String? { didSet { label.text = message; label.isHidden = message == nil } }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .tertiarySystemFill
    layer.cornerRadius = 18
    layer.cornerCurve = .continuous
    clipsToBounds = true
    imageView.contentMode = .scaleAspectFit
    label.textAlignment = .center
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: 32)
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.6
    label.textColor = .label
    [imageView, label, spinner].forEach(addSubview)
    isUserInteractionEnabled = false
  }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  deinit { task?.cancel(); decodeTask?.cancel(); timer?.invalidate() }
  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = bounds
    label.frame = bounds.insetBy(dx: 8, dy: 6)
    spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
  }
  func reset() {
    token = UUID()
    task?.cancel(); task = nil
    decodeTask?.cancel(); decodeTask = nil
    isLoaded = false
    loadedURL = nil; loadedText = nil
    timer?.invalidate(); timer = nil
    source = nil; frameIndex = 0; displayedFrameCount = 0
    imageView.image = nil
    message = nil
    spinner.stopAnimating()
  }
  func load(_ url: URL?, text: String? = nil, animating: Bool = true) {
    guard !isLoaded || loadedURL != url || loadedText != text || self.animating != animating else { return }
    reset()
    isLoaded = true
    loadedURL = url; loadedText = text; self.animating = animating
    message = text
    guard let url else { return }
    spinner.startAnimating()
    let token = self.token
    task = Task { [weak self] in
      do {
        let local = url.isFileURL ? url : try await KeyboardMediaSearch.download(url, maxBytes: 2 * 1024 * 1024)
        defer { if !url.isFileURL { try? FileManager.default.removeItem(at: local) } }
        // Data keeps the compressed source alive after the temporary download is removed.
        let worker = Task.detached(priority: .utility) { () async throws -> CGImageSource in
          try Task.checkCancellation()
          let size = try local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
          guard size <= 8 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
          let data = try Data(contentsOf: local, options: .mappedIfSafe)
          return try await KeyboardPreviewDecoder.shared.source(data: data)
        }
        let source = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, let self, self.token == token else { return }
        self.source = source
        self.spinner.stopAnimating()
        self.displayFrame()
      } catch {
        guard !Task.isCancelled, let self, self.token == token else { return }
        self.spinner.stopAnimating()
        self.message = "Preview unavailable"
      }
    }
  }
  func load(data: Data) {
    reset()
    animating = true
    let token = self.token
    task = Task { [weak self] in
      do {
        let source = try await KeyboardPreviewDecoder.shared.source(data: data)
        guard !Task.isCancelled, let self, self.token == token else { return }
        self.source = source
        self.displayFrame()
      } catch {
        guard !Task.isCancelled, let self, self.token == token else { return }
        self.message = "Preview unavailable"
      }
    }
  }
  private func displayFrame() {
    guard let source, decodeTask == nil else { return }
    let token = self.token
    let index = frameIndex
    decodeTask = Task { [weak self] in
      let frame = await KeyboardPreviewDecoder.shared.frame(source: source, index: index)
      guard !Task.isCancelled, let self, self.token == token else { return }
      self.decodeTask = nil
      guard let image = frame.image else {
        self.source = nil
        self.message = "Preview unavailable"
        return
      }
      self.imageView.image = UIImage(cgImage: image)
      self.displayedFrameCount += 1
      if !self.animating || frame.count == 1 {
        self.source = nil // Still cells retain only their downsampled pixels.
        return
      }
      guard self.window != nil, !self.isHidden, !UIAccessibility.isReduceMotionEnabled else { return }
      let timer = Timer(timeInterval: frame.delay, repeats: false) { [weak self] _ in
        guard let self else { return }
        self.timer = nil
        self.frameIndex = frame.nextIndex
        self.displayFrame()
      }
      self.timer = timer
      RunLoop.main.add(timer, forMode: .common)
    }
  }
  override var isHidden: Bool {
    didSet {
      if isHidden { timer?.invalidate(); timer = nil }
      else if window != nil, timer == nil { displayFrame() }
    }
  }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    timer?.invalidate(); timer = nil
    if window != nil { displayFrame() }
    else { decodeTask?.cancel(); decodeTask = nil }
  }
}

/// Serial ImageIO work prevents several visible GIFs from allocating full decode
/// scratch buffers concurrently. Only one downsampled frame is kept per preview.
private actor KeyboardPreviewDecoder {
  static let shared = KeyboardPreviewDecoder()
  private let maxPixelSize = 160
  private let minimumFrameInterval = 1.0 / 8

  func source(data: Data) throws -> CGImageSource {
    try Task.checkCancellation()
    guard data.count <= 8 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 4096, height <= 4096,
      width * height <= 4 * 1024 * 1024 else { throw URLError(.cannotDecodeContentData) }
    return source
  }

  func frame(source: CGImageSource, index: Int) -> (image: CGImage?, count: Int, nextIndex: Int, delay: Double) {
    autoreleasepool {
      let count = CGImageSourceGetCount(source)
      guard !Task.isCancelled, count > 0 else { return (nil, 0, 0, 0) }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCache: false,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
      CGImageSourceRemoveCacheAtIndex(source, index)
      // Skip intermediate frames instead of slowing the GIF's timeline.
      var delay = 0.0, next = index
      repeat {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, next, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let duration = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
          ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
        delay += duration.isFinite && duration >= 0.02 ? duration : 0.1
        next = (next + 1) % count
      } while delay < minimumFrameInterval && next != index
      return (image, count, next, max(minimumFrameInterval, delay))
    }
  }
}

final class KeyboardMediaCell: UICollectionViewCell {
  let preview = KeyboardMediaPreview()
  private let feedback = UILabel()
  private let caption = UILabel()
  override var isHighlighted: Bool {
    didSet {
      KeyboardAppearance.animate { self.contentView.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity }
    }
  }
  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.addSubview(preview)
    contentView.addSubview(feedback)
    contentView.addSubview(caption)
    caption.font = .systemFont(ofSize: 10, weight: .semibold)
    caption.textColor = .white
    caption.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    caption.textAlignment = .center
    caption.layer.cornerRadius = 7
    caption.clipsToBounds = true
    caption.isUserInteractionEnabled = false
    feedback.font = .systemFont(ofSize: 13, weight: .semibold)
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
    preview.frame = bounds
    feedback.frame = CGRect(x: 6, y: 6, width: bounds.width - 12, height: 30)
    let captionWidth = min(bounds.width - 16, caption.intrinsicContentSize.width + 12)
    caption.frame = CGRect(x: 8, y: bounds.height - 24, width: captionWidth, height: 16)
  }
  override func prepareForReuse() { super.prepareForReuse(); preview.reset(); showFeedback(nil); setCaption(""); contentView.transform = .identity }
  func setCaption(_ text: String) { caption.text = text; caption.isHidden = text.isEmpty; setNeedsLayout() }
  func showFeedback(_ text: String?) { feedback.text = text; feedback.isHidden = text == nil }
}
