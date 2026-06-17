//
//  CatchUpSubviews.swift
//  Clip
//

import UIKit

/// The full-screen end-of-catch-up message (delete prompt / all done): a large
/// accent SF Symbol over bold text, centered — in the app's own aesthetic.
final class CatchUpMessageView: UIView {
    private let glyph = UIImageView()
    private let textLabel = UILabel()

    init() {
        super.init(frame: .zero)
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 52, weight: .semibold)
        textLabel.font = .systemFont(ofSize: 28, weight: .bold)
        textLabel.textColor = .label
        textLabel.textAlignment = .center
        textLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [glyph, textLabel])
        stack.axis = .vertical
        stack.spacing = 22
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(symbol: String, tint: UIColor, text: String) {
        glyph.image = UIImage(systemName: symbol)
        glyph.tintColor = tint
        textLabel.text = text
    }
}

/// The strip at the top of a catch-up card: the bump date (or save date) and the
/// friend who sent it, if any.
final class CatchUpCardHeader: UIView {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    init(item: ReadingListItem) {
        super.init(frame: .zero)
        backgroundColor = ReaderDepth.backgroundColor(for: 0)

        let dateLabel = UILabel()
        let bumped = item.bumpDate != nil
        let date = item.bumpDate ?? item.dateAdded
        var text = (bumped ? "Bumped " : "") + Self.formatter.string(from: date)
        if let friend = item.sharedByUsername { text += " · from \(friend)" }
        dateLabel.text = text
        dateLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        dateLabel.textColor = .secondaryLabel
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dateLabel)
        NSLayoutConstraint.activate([
            dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            dateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            dateLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A media/link catch-up card body: the thumbnail (above the text, using the extra
/// vertical space), title, and a secondary line; the whole thing taps to open.
final class CatchUpMediaCardBody: UIView {
    private let onTap: () -> Void

    init(item: ReadingListItem, store: ReadingListStore, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        backgroundColor = ReaderDepth.backgroundColor(for: 0)

        let thumb = UIImageView()
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 12
        thumb.backgroundColor = .secondarySystemFill
        thumb.translatesAutoresizingMaskIntoConstraints = false
        configureThumbnail(thumb, item: item, store: store)

        let title = UILabel()
        title.text = item.title ?? item.urlString
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.numberOfLines = 4

        let subtitle = UILabel()
        subtitle.text = mediaSubtitle(for: item)
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 2

        let openHint = UILabel()
        openHint.text = "Tap to open"
        openHint.font = .systemFont(ofSize: 14, weight: .semibold)
        openHint.textColor = GlassStyle.readingAccent

        let stack = UIStackView(arrangedSubviews: [thumb, title, subtitle, openHint])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.setCustomSpacing(20, after: thumb)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            thumb.heightAnchor.constraint(equalTo: thumb.widthAnchor, multiplier: 9.0 / 16.0),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func tapped() { onTap() }

    private func configureThumbnail(_ imageView: UIImageView, item: ReadingListItem, store: ReadingListStore) {
        if let fileName = item.thumbnailFileName,
           let image = UIImage(contentsOfFile: store.articlesDirectory.appendingPathComponent(fileName).path) {
            imageView.image = image
            return
        }
        if let platform = item.contentPlatform {
            if let asset = platform.logoAssetName, let logo = UIImage(named: asset) {
                imageView.image = logo
                imageView.contentMode = .scaleAspectFit
                return
            }
            if let module = PlatformRegistry.shared.module(for: platform) {
                imageView.image = UIImage(systemName: module.glyphSymbolName)
                imageView.contentMode = .center
                imageView.tintColor = .secondaryLabel
            }
        }
    }

    private func mediaSubtitle(for item: ReadingListItem) -> String? {
        if let platform = item.contentPlatform,
           let module = PlatformRegistry.shared.module(for: platform),
           let subtitle = module.subtitle(for: item) {
            return subtitle
        }
        return item.url?.host?.replacingOccurrences(of: "www.", with: "")
    }
}
