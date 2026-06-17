//
//  ReadingListItemCell.swift
//  Clip
//

import UIKit

/// A reading-list row with a title, a metadata subtitle, and a thumbnail that
/// has three states: a spinner while the item's image is still being fetched,
/// the fetched art (aspect-fit, ratio-capped), or a platform-logo fallback once
/// the fetch has finished without an image. Art decodes off the main thread and
/// is guarded by `reuseKey` so a slow load never lands on a recycled cell.
final class ReadingListItemCell: UITableViewCell {
    static let reuseID = "readingListItemCell"

    /// What to show in the thumbnail well.
    enum Thumbnail {
        /// No thumbnail well at all (plain article with no art).
        case none
        /// Still fetching — show a spinner.
        case loading
        /// Fetched art on disk at this path.
        case art(path: String)
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
    private let spinner = UIActivityIndicatorView(style: .medium)

    /// Identifies the item currently configured, so an async art load that
    /// resolves after the cell is reused is discarded.
    private var reuseKey: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildLayout() {
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.numberOfLines = 2
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.numberOfLines = 1

        thumbContainer.backgroundColor = .secondarySystemFill
        thumbContainer.layer.cornerRadius = 6
        thumbContainer.layer.cornerCurve = .continuous
        thumbContainer.clipsToBounds = true

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
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        reuseKey = nil
        thumbImageView.image = nil
        spinner.stopAnimating()
    }

    func configure(
        title: String, titleColor: UIColor, subtitle: NSAttributedString,
        thumbnail: Thumbnail, showsDisclosure: Bool, reuseKey: String
    ) {
        self.reuseKey = reuseKey
        titleLabel.text = title
        titleLabel.textColor = titleColor
        subtitleLabel.attributedText = subtitle
        accessoryType = showsDisclosure ? .disclosureIndicator : .none

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
            spinner.startAnimating()
            loadArt(path: path, expecting: reuseKey)
        case .logo(let assetName, let glyph):
            thumbContainer.isHidden = false
            spinner.stopAnimating()
            showLogo(assetName: assetName, glyph: glyph)
        }
    }

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

    private func loadArt(path: String, expecting key: String) {
        Task.detached(priority: .userInitiated) {
            let image = UIImage(contentsOfFile: path)
            await MainActor.run { [weak self] in
                guard let self, self.reuseKey == key else { return }
                self.spinner.stopAnimating()
                guard let image else { return }
                self.thumbImageView.tintColor = nil
                self.thumbImageView.contentMode = Self.contentMode(for: image.size)
                self.thumbImageView.image = image
            }
        }
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
