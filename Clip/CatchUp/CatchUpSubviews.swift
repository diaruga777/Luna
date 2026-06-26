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

    /// The date/sender line for a card ("Bumped <date> · from <friend>"). Shared with
    /// the reader's inline glass header so an article card needs no separate strip.
    static func text(for item: ReadingListItem) -> String {
        let bumped = item.bumpDate != nil
        let date = item.bumpDate ?? item.dateAdded
        var text = (bumped ? "Bumped " : "") + formatter.string(from: date)
        if let friend = item.sharedByUsername { text += " · from \(friend)" }
        return text
    }

    init(item: ReadingListItem) {
        super.init(frame: .zero)
        // Clear so the card's glass backdrop shows through the forehead.
        backgroundColor = .clear

        let dateLabel = UILabel()
        dateLabel.text = Self.text(for: item)
        dateLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        dateLabel.textColor = .secondaryLabel
        // Centered, so the top corners stay empty for the Bump / Read glass pills.
        dateLabel.textAlignment = .center
        dateLabel.numberOfLines = 1
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dateLabel)
        NSLayoutConstraint.activate([
            // Inset from the corners so the date never sits under the corner pills.
            dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 96),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -96),
            dateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            dateLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
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
        // Clear so the card's glass backdrop shows through.
        backgroundColor = .clear

        let thumb = UIImageView()
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 12
        thumb.backgroundColor = .secondarySystemFill
        thumb.translatesAutoresizingMaskIntoConstraints = false
        configureThumbnail(thumb, item: item, store: store)

        let title = UILabel()
        title.text = item.title ?? item.urlString
        title.font = .systemFont(ofSize: 20, weight: .bold)
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
        // Centered vertically so the top of the card stays clear (a "forehead" for
        // the Bump / Read pills) rather than the media hugging the top edge.
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 56),
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

/// A small, NON-tappable table of a price tracker's tracked sites: one row per
/// store, the site host on the left and its price right-aligned, no chevron and no
/// selection. The row holding the current best (lowest fetched) price is highlighted
/// — accent-tinted, bold price — so the cheapest seller stands out.
final class PriceTrackerStoreRowsView: UIView {

    init(tracker: PriceTracker) {
        super.init(frame: .zero)
        backgroundColor = .clear

        let bestStoreID = tracker.bestPriceStoreID
        let rows = tracker.stores.map { store -> UIView in
            Self.makeRow(store: store, isBest: store.id == bestStoreID)
        }
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 0
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

    /// One seller row: host on the left, price right-aligned. The best-price row is
    /// accent-tinted and bold to mark the cheapest seller.
    private static func makeRow(store: PriceTrackerStore, isBest: Bool) -> UIView {
        let hostLabel = UILabel()
        hostLabel.text = store.url?.host?.replacingOccurrences(of: "www.", with: "")
            ?? store.urlString
        hostLabel.font = .systemFont(ofSize: 15, weight: isBest ? .semibold : .regular)
        hostLabel.textColor = isBest ? GlassStyle.readingAccent : .label
        hostLabel.lineBreakMode = .byTruncatingTail
        hostLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let priceLabel = UILabel()
        if let price = store.lastPrice {
            priceLabel.text = PriceFormatting.string(amount: price, currency: store.currency)
        } else {
            priceLabel.text = "—"
        }
        priceLabel.font = .systemFont(ofSize: 15, weight: isBest ? .bold : .regular)
        priceLabel.textColor = isBest ? GlassStyle.readingAccent : .secondaryLabel
        priceLabel.textAlignment = .right
        priceLabel.setContentHuggingPriority(.required, for: .horizontal)
        priceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [hostLabel, priceLabel])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        return row
    }
}

/// A catch-up card body for a PRICE TRACKER (top→bottom): a small product thumbnail,
/// the product name, a non-tappable mini-table of the tracked sites (host + price,
/// best price highlighted), and a READ-ONLY alert-threshold readout with a "Change"
/// button. Catch-up is a glance surface, so editing happens on the full price-tracking
/// screen (`PriceTrackingViewController`) — the button navigates there via `onChangeThreshold`.
final class CatchUpPriceTrackerCardBody: UIView {

    /// Fired when the user taps "Change" — the host opens the full price-tracking
    /// screen (where the shared `AlertThresholdSlider` lives) for this tracker.
    var onChangeThreshold: (() -> Void)?

    init(item: ReadingListItem, tracker: PriceTracker, store: ReadingListStore) {
        super.init(frame: .zero)
        backgroundColor = .clear

        let thumb = UIImageView()
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 12
        thumb.layer.cornerCurve = .continuous
        thumb.backgroundColor = .secondarySystemFill
        thumb.translatesAutoresizingMaskIntoConstraints = false
        Self.configureThumbnail(thumb, tracker: tracker, store: store)

        // The thumbnail lives inside a full-width row so the stack's `.fill` alignment
        // stretches the ROW, not the image — otherwise fill pins the image edge-to-edge
        // and it balloons to the whole card. The image is forced to a small fixed size,
        // centred in the row.
        let thumbRow = UIView()
        thumbRow.translatesAutoresizingMaskIntoConstraints = false
        thumbRow.addSubview(thumb)

        let title = UILabel()
        title.text = tracker.productName
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textAlignment = .center
        title.numberOfLines = 3

        let rows = PriceTrackerStoreRowsView(tracker: tracker)
        rows.translatesAutoresizingMaskIntoConstraints = false

        // The tracked-sites list scrolls when there are more sites than fit — it's the
        // flexible element, so it never pushes the threshold readout off the card.
        let rowsScroll = UIScrollView()
        rowsScroll.translatesAutoresizingMaskIntoConstraints = false
        rowsScroll.showsVerticalScrollIndicator = true
        rowsScroll.alwaysBounceVertical = false
        rowsScroll.contentInsetAdjustmentBehavior = .never
        rowsScroll.addSubview(rows)
        rowsScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        rowsScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let thresholdReadout = Self.makeThresholdReadout(tracker: tracker) { [weak self] in
            self?.onChangeThreshold?()
        }

        let stack = UIStackView(arrangedSubviews: [thumbRow, title, rowsScroll, thresholdReadout])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.setCustomSpacing(10, after: thumbRow)
        stack.setCustomSpacing(6, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        // Pin the content below the corner pills, filling the card so the rows
        // scroll-area gets the leftover height (and the threshold stays pinned low).
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 56),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            // A small, fixed-size thumbnail centred in its full-width row.
            thumb.widthAnchor.constraint(equalToConstant: 64),
            thumb.heightAnchor.constraint(equalToConstant: 64),
            thumb.centerXAnchor.constraint(equalTo: thumbRow.centerXAnchor),
            thumb.topAnchor.constraint(equalTo: thumbRow.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: thumbRow.bottomAnchor),
            // The scrolled list's content is exactly the scroll viewport wide and as
            // tall as its rows (so vertical overflow scrolls).
            rows.topAnchor.constraint(equalTo: rowsScroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: rowsScroll.contentLayoutGuide.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: rowsScroll.contentLayoutGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: rowsScroll.contentLayoutGuide.trailingAnchor),
            rows.widthAnchor.constraint(equalTo: rowsScroll.frameLayoutGuide.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A read-only liquid-glass pill mirroring `AlertThresholdSlider`'s chrome — the
    /// "Alert threshold" title and the SAME percent + absolute readout
    /// (`PriceFormatting.thresholdDescription`) — but with a "Change" button instead
    /// of the interactive slider, since catch-up is a glance surface (editing happens
    /// on the full price-tracking screen).
    private static func makeThresholdReadout(
        tracker: PriceTracker, onChange: @escaping () -> Void
    ) -> UIView {
        let glassPill = UIVisualEffectView(effect: GlassStyle.barEffect())
        glassPill.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 26.0, *) {
            glassPill.cornerConfiguration = .corners(radius: 22)
        } else {
            glassPill.layer.cornerRadius = 22
            glassPill.layer.cornerCurve = .continuous
            glassPill.clipsToBounds = true
        }

        let title = UILabel()
        title.text = "Alert threshold"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .label

        let readout = UILabel()
        // "25% off" and "alert below <price>" on their own lines (the formatter joins
        // them with " — "; break it so each reads cleanly and leaves horizontal room).
        let description = PriceFormatting.thresholdDescription(
            fraction: tracker.alertThresholdFraction,
            initialPrice: tracker.initialPrice, currency: tracker.initialCurrency)
        readout.text = description.replacingOccurrences(of: " — ", with: "\n")
        readout.font = .preferredFont(forTextStyle: .subheadline)
        readout.textColor = .secondaryLabel
        readout.numberOfLines = 0

        // A small, low-key text button — less prominent than a filled capsule, so the
        // threshold copy keeps the horizontal room.
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Change"
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .footnote)
            return outgoing
        }
        let changeButton = UIButton(configuration: configuration)
        changeButton.setContentHuggingPriority(.required, for: .horizontal)
        changeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        changeButton.addAction(UIAction { _ in onChange() }, for: .touchUpInside)

        let copy = UIStackView(arrangedSubviews: [title, readout])
        copy.axis = .vertical
        copy.spacing = 3
        copy.alignment = .leading
        copy.translatesAutoresizingMaskIntoConstraints = false
        glassPill.contentView.addSubview(copy)
        changeButton.translatesAutoresizingMaskIntoConstraints = false
        glassPill.contentView.addSubview(changeButton)
        // Text on the left, a self-sized capsule "Change" button on the right, side by
        // side with a real gap — so the button is an unambiguous tap target and the
        // multi-line readout can never run underneath it.
        NSLayoutConstraint.activate([
            copy.topAnchor.constraint(equalTo: glassPill.contentView.topAnchor, constant: 12),
            copy.leadingAnchor.constraint(equalTo: glassPill.contentView.leadingAnchor, constant: 16),
            copy.bottomAnchor.constraint(equalTo: glassPill.contentView.bottomAnchor, constant: -12),
            changeButton.leadingAnchor.constraint(equalTo: copy.trailingAnchor, constant: 12),
            changeButton.trailingAnchor.constraint(equalTo: glassPill.contentView.trailingAnchor, constant: -16),
            changeButton.centerYAnchor.constraint(equalTo: glassPill.contentView.centerYAnchor),
        ])
        return glassPill
    }

    /// Resolves the tracker's product image the SAME way the reading-list cell does
    /// (`PriceTracker.imageFileName` inside the Articles directory), falling back to a
    /// `tag` glyph when there's no image — so the card shows the identical thumbnail.
    private static func configureThumbnail(
        _ imageView: UIImageView, tracker: PriceTracker, store: ReadingListStore
    ) {
        if let fileName = tracker.imageFileName,
           let data = try? Data(contentsOf: store.articlesDirectory.appendingPathComponent(fileName)),
           let image = UIImage(data: data) {
            imageView.image = image
            return
        }
        imageView.image = UIImage(
            systemName: tracker.isAlerting ? "tag.fill" : "tag",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold))
        imageView.contentMode = .center
        imageView.tintColor = .secondaryLabel
    }
}
