//
//  ReadingListItemCell.swift
//  Clip
//

import ClipModels
import ClipDesignSystem
import ImageIO
import UIKit

/// A reading-list row with a title, a metadata subtitle, and a thumbnail that
/// has three states: a spinner while the item's image is still being fetched,
/// the fetched art (aspect-fit, ratio-capped), or a platform-logo fallback once
/// the fetch has finished without an image.
///
/// Art bytes live on disk, but decoding them is the only slow part. Already-decoded
/// thumbnails are held in a small in-memory `NSCache` keyed by file path, so a row
/// that has been seen before (scrolled away and back) renders **synchronously** in
/// `configure(…)` with no spinner flash. Only a genuine cache miss (first decode of
/// a file) decodes off the main thread behind a spinner. Async results are guarded
/// by a per-cell `loadToken` so a slow decode never lands on a recycled cell.
public final class ReadingListItemCell: UITableViewCell {
    public static let reuseID = "readingListItemCell"

    /// In-memory cache of already-decoded, downsampled thumbnails. The bytes are on
    /// disk, but decoding is the visible cost — caching the decoded bitmap makes a
    /// re-seen row appear instantly with no spinner. Keyed by file path. Bounded so a
    /// long session can't accumulate bitmaps unboundedly (NSCache also evicts under
    /// memory pressure). Mirrors `ArticleTextRenderer`'s decoded-image cache.
    nonisolated(unsafe) private static let decodedCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    /// What to show in the thumbnail well.
    public enum Thumbnail {
        /// No thumbnail well at all (plain article with no art).
        case none
        /// Still fetching — show a spinner.
        case loading
        /// Fetched art on disk at this path.
        case art(path: String)
        /// An already-loaded image (e.g. a pasteboard preview thumbnail).
        case image(UIImage)
        /// Fetch finished with no art — show the platform logo (or SF glyph).
        case logo(assetName: String?, glyph: String)
    }

    private static let thumbSize = CGSize(width: 96, height: 54)
    /// Container aspect ratio; art whose ratio stays within [R/2, R*2] is shown
    /// aspect-fit (its smaller rendered dimension then fills ≥ half the well);
    /// more extreme ratios switch to aspect-fill so they never letterbox below half.
    private static let containerRatio = thumbSize.width / thumbSize.height

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let thumbContainer = UIView()
    private let thumbImageView = UIImageView()
    private let spinner = DotMatrixSpinnerView()
    private let trailingButton = UIButton(type: .system)
    /// Simulator-only: a small bottom-left hit target that opens the row's
    /// context menu on a plain tap (the automation harness can't long-press).
    private let simulatorMenuButton = UIButton(type: .system)

    /// Identifies the item currently configured, so an async art load that
    /// resolves after the cell is reused is discarded.
    private var reuseKey: String?
    /// Monotonic token bumped on every (re)configuration and on reuse. An in-flight
    /// async decode captures the token it was started with and discards its result if
    /// the token has since moved on — robust even if the same item lands back on the
    /// same recycled cell instance (where `reuseKey` alone would match).
    private var loadToken: UInt64 = 0
    /// Action for the optional trailing button (e.g. the pasteboard row's Save).
    private var onTrailingButton: (() -> Void)?

    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        buildLayout()
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    private func buildLayout() {
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.numberOfLines = 2
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.numberOfLines = 1

        thumbContainer.backgroundColor = .secondarySystemFill
        thumbContainer.layer.cornerRadius = 6
        thumbContainer.layer.cornerCurve = .continuous
        thumbContainer.clipsToBounds = true

        trailingButton.addTarget(self, action: #selector(trailingButtonTapped), for: .touchUpInside)

        thumbImageView.clipsToBounds = true
        thumbImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbContainer.addSubview(thumbImageView)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        thumbContainer.addSubview(spinner)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 3

        let row = UIStackView(arrangedSubviews: [thumbContainer, textStack])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        thumbContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            thumbContainer.widthAnchor.constraint(equalToConstant: Self.thumbSize.width),
            thumbContainer.heightAnchor.constraint(equalToConstant: Self.thumbSize.height),
            thumbImageView.leadingAnchor.constraint(equalTo: thumbContainer.leadingAnchor),
            thumbImageView.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor),
            thumbImageView.topAnchor.constraint(equalTo: thumbContainer.topAnchor),
            thumbImageView.bottomAnchor.constraint(equalTo: thumbContainer.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: thumbContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: thumbContainer.centerYAnchor),
        ])

        if AppEnvironment.isSimulator {
            simulatorMenuButton.translatesAutoresizingMaskIntoConstraints = false
            simulatorMenuButton.showsMenuAsPrimaryAction = true
            simulatorMenuButton.tintColor = .tertiaryLabel
            simulatorMenuButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
            simulatorMenuButton.accessibilityLabel = "Row actions"
            simulatorMenuButton.isHidden = true
            contentView.addSubview(simulatorMenuButton)
            NSLayoutConstraint.activate([
                simulatorMenuButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
                simulatorMenuButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
                simulatorMenuButton.widthAnchor.constraint(equalToConstant: 30),
                simulatorMenuButton.heightAnchor.constraint(equalToConstant: 30),
            ])
        }
    }

    /// Simulator-only: install the row's context menu on the bottom-left tap target.
    public func setSimulatorMenu(_ menu: UIMenu?) {
        guard AppEnvironment.isSimulator else { return }
        simulatorMenuButton.menu = menu
        simulatorMenuButton.isHidden = menu == nil
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        reuseKey = nil
        loadToken &+= 1   // invalidate any in-flight async decode
        thumbImageView.image = nil
        spinner.stopAnimating()
        onTrailingButton = nil
        setSimulatorMenu(nil)
    }

    public func configure(
        title: String, titleColor: UIColor, subtitle: NSAttributedString,
        thumbnail: Thumbnail, showsDisclosure: Bool, reuseKey: String,
        trailingButtonSymbol: String? = nil, onTrailingButton: (() -> Void)? = nil
    ) {
        self.reuseKey = reuseKey
        loadToken &+= 1   // invalidate any decode started for the previous content
        titleLabel.text = title
        titleLabel.textColor = titleColor
        subtitleLabel.attributedText = subtitle

        // A trailing tappable button (pasteboard "Save") takes the accessory slot;
        // otherwise the usual chevron. The list runs in permanent edit mode, so the
        // button must be the EDITING accessory too (the plain `accessoryView` is
        // hidden while editing) — that's why it didn't appear before.
        self.onTrailingButton = onTrailingButton
        if let symbol = trailingButtonSymbol {
            trailingButton.setImage(
                UIImage(systemName: symbol, withConfiguration:
                    UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)), for: .normal)
            trailingButton.sizeToFit()
            trailingButton.tintColor = GlassStyle.readingAccent
            accessoryView = trailingButton
            editingAccessoryView = trailingButton
        } else {
            accessoryView = nil
            editingAccessoryView = nil
            accessoryType = showsDisclosure ? .disclosureIndicator : .none
            editingAccessoryType = .none
        }

        switch thumbnail {
        case .none:
            thumbContainer.isHidden = true
            thumbImageView.image = nil
            spinner.stopAnimating()
        case .loading:
            thumbContainer.isHidden = false
            thumbImageView.image = nil
            spinner.startAnimating()
        case .art(let path):
            thumbContainer.isHidden = false
            // Cache hit: the bitmap is already decoded — show it synchronously, before
            // the cell is displayed, with no spinner. Only a true miss spins + decodes.
            if let cached = Self.decodedCache.object(forKey: path as NSString) {
                spinner.stopAnimating()
                applyArt(cached)
            } else {
                thumbImageView.image = nil
                spinner.startAnimating()
                loadArt(path: path, token: loadToken)
            }
        case .image(let image):
            thumbContainer.isHidden = false
            spinner.stopAnimating()
            thumbImageView.tintColor = nil
            thumbImageView.contentMode = Self.contentMode(for: image.size)
            thumbImageView.image = image
        case .logo(let assetName, let glyph):
            thumbContainer.isHidden = false
            spinner.stopAnimating()
            showLogo(assetName: assetName, glyph: glyph)
        }
    }

    @objc private func trailingButtonTapped() { onTrailingButton?() }

    private func showLogo(assetName: String?, glyph: String) {
        // Full-color brand logo (untinted) when bundled, else a tinted SF glyph.
        if let assetName, let logo = UIImage(named: assetName) {
            thumbImageView.image = logo
            thumbImageView.contentMode = .scaleAspectFit
            thumbImageView.tintColor = nil
        } else {
            thumbImageView.image = UIImage(systemName: glyph)?
                .withRenderingMode(.alwaysTemplate)
            thumbImageView.tintColor = .secondaryLabel
            thumbImageView.contentMode = .center
        }
    }

    /// Sets `image` as the art (no spinner, correct content mode/tint). Main-thread.
    private func applyArt(_ image: UIImage) {
        spinner.stopAnimating()
        thumbImageView.tintColor = nil
        thumbImageView.contentMode = Self.contentMode(for: image.size)
        thumbImageView.image = image
    }

    /// Cache miss only: decode (downsampled) off the main thread, populate the cache,
    /// then land the result iff this cell hasn't been reconfigured/recycled since
    /// (`loadToken` unchanged). Downsampling means we never hold the full-size bitmap.
    private func loadArt(path: String, token: UInt64) {
        // Read the screen scale on the main thread; the detached decode must not touch
        // main-actor UIKit state.
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        Task.detached(priority: .userInitiated) {
            // Re-check the cache on the worker: a sibling cell may have decoded the
            // same file while this task was queued.
            let image = Self.decodedCache.object(forKey: path as NSString)
                ?? Self.decodeThumbnail(path: path, scale: scale)
            if let image { Self.decodedCache.setObject(image, forKey: path as NSString) }
            await MainActor.run { [weak self] in
                guard let self, self.loadToken == token else { return }
                self.spinner.stopAnimating()
                guard let image else { return }
                self.applyArt(image)
            }
        }
    }

    /// Decodes the file already scaled down to ~thumbnail size (capped at 2× the
    /// container's longest side, in pixels) so a large cover image isn't held at full
    /// resolution for a 96×54 well. `nil` if the file is missing/undecodable.
    nonisolated private static func decodeThumbnail(path: String, scale: CGFloat) -> UIImage? {
        let url = URL(fileURLWithPath: path)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let maxPixel = max(thumbSize.width, thumbSize.height) * 2 * scale
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }

    /// Aspect-fit unless the image is more extreme than 2× the container ratio in
    /// either direction (then aspect-fill, so the smaller dimension fills ≥ half).
    private static func contentMode(for imageSize: CGSize) -> UIView.ContentMode {
        guard imageSize.width > 0, imageSize.height > 0 else { return .scaleAspectFit }
        let ratio = imageSize.width / imageSize.height
        let withinCap = ratio <= containerRatio * 2 && ratio >= containerRatio / 2
        return withinCap ? .scaleAspectFit : .scaleAspectFill
    }
}
