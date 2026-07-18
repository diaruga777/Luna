//
//  CatchUpSubviews.swift
//  Luna
//

import LunaPriceUI
import LunaPlatforms
import LunaDesignSystem
import LunaStorage
import LunaModels
import UIKit

/// The full-screen end-of-catch-up message (delete prompt / all done): a large
/// accent SF Symbol over bold text, centered — in the app's own aesthetic.
///
/// The glyph slot is a fixed-size square so it can host either a static SF Symbol
/// (the delete prompt's `trash` etc.) OR a vector-drawn, animatable checkmark (the
/// "All done!" celebration). The checkmark is drawn with CAShapeLayers so the ring
/// can spring-pop in and the tick can stroke on — see `playDoneCheckmark`.
final class CatchUpMessageView: UIView {
    private let glyph = UIImageView()
    private let textLabel = UILabel()

    /// The fixed square that holds whichever glyph (symbol or drawn check) is shown.
    /// A constant size keeps layout stable whether we show a symbol or draw vectors,
    /// and gives the shape layers a deterministic canvas to lay out into.
    private static let glyphSize: CGFloat = 84
    private let glyphContainer = UIView()

    // Vector checkmark layers (lazily built on first `playDoneCheckmark`). The ring is
    // a stroked circle; the tick is a stroked check path. Kept around so an in-flight
    // animation can be torn down cleanly if the view is reused.
    private var ringLayer: CAShapeLayer?
    private var checkLayer: CAShapeLayer?

    init() {
        super.init(frame: .zero)
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 52, weight: .semibold)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        glyphContainer.translatesAutoresizingMaskIntoConstraints = false
        glyphContainer.addSubview(glyph)

        textLabel.font = .systemFont(ofSize: 28, weight: .bold)
        textLabel.textColor = .label
        textLabel.textAlignment = .center
        textLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [glyphContainer, textLabel])
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
            glyphContainer.widthAnchor.constraint(equalToConstant: Self.glyphSize),
            glyphContainer.heightAnchor.constraint(equalToConstant: Self.glyphSize),
            glyph.centerXAnchor.constraint(equalTo: glyphContainer.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: glyphContainer.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(symbol: String, tint: UIColor, text: String) {
        // Showing a plain symbol replaces any drawn checkmark from a prior use.
        tearDownCheckmarkLayers()
        glyph.isHidden = false
        glyph.image = UIImage(systemName: symbol)
        glyph.tintColor = tint
        textLabel.text = text
    }

    /// Sets up the "All done!" message and plays a celebratory checkmark: the accent
    /// ring springs/pops in while the tick strokes on, landing on a settled checkmark.
    /// `completion` fires once the tick has finished drawing (or immediately-ish under
    /// Reduce Motion, where we just show the finished mark). Independent of the
    /// This is pure Core Animation.
    ///
    /// - Parameter tint: the accent color for the ring + tick.
    /// - Parameter text: the headline ("All done!").
    func playDoneCheckmark(tint: UIColor, text: String, completion: @escaping () -> Void) {
        textLabel.text = text
        glyph.isHidden = true          // hide the static symbol slot; we draw vectors
        glyph.image = nil

        // Lay out so the container has its final size before we build the shapes.
        layoutIfNeeded()
        buildCheckmarkLayers(tint: tint)

        if UIAccessibility.isReduceMotionEnabled {
            // Reduce Motion: skip the draw-on. Snap the finished mark on screen and let
            // the caller hold/auto-dismiss. Still calls completion so the user is never
            // stranded on the done screen.
            ringLayer?.strokeEnd = 1
            checkLayer?.strokeEnd = 1
            completion()
            return
        }

        animateCheckmark(completion: completion)
    }

    // MARK: - Vector checkmark

    private func tearDownCheckmarkLayers() {
        ringLayer?.removeAllAnimations(); ringLayer?.removeFromSuperlayer(); ringLayer = nil
        checkLayer?.removeAllAnimations(); checkLayer?.removeFromSuperlayer(); checkLayer = nil
    }

    /// Builds (or rebuilds) the ring + tick shape layers, sized to the glyph square and
    /// starting fully un-drawn (`strokeEnd = 0`) ready to animate.
    private func buildCheckmarkLayers(tint: UIColor) {
        tearDownCheckmarkLayers()
        let size = Self.glyphSize
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let lineWidth: CGFloat = 6

        // Ring: a full circle inset by half the stroke so it isn't clipped.
        let ring = CAShapeLayer()
        ring.frame = bounds
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = tint.cgColor
        ring.lineWidth = lineWidth
        ring.lineCap = .round
        let ringRect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        // Start the stroke at the top so it sweeps around symmetrically.
        let ringPath = UIBezierPath(
            arcCenter: CGPoint(x: size / 2, y: size / 2),
            radius: ringRect.width / 2,
            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true)
        ring.path = ringPath.cgPath
        ring.strokeEnd = 0

        // Tick: the classic check, proportioned to the square.
        let check = CAShapeLayer()
        check.frame = bounds
        check.fillColor = UIColor.clear.cgColor
        check.strokeColor = tint.cgColor
        check.lineWidth = lineWidth
        check.lineCap = .round
        check.lineJoin = .round
        let tick = UIBezierPath()
        tick.move(to: CGPoint(x: size * 0.28, y: size * 0.52))
        tick.addLine(to: CGPoint(x: size * 0.44, y: size * 0.68))
        tick.addLine(to: CGPoint(x: size * 0.73, y: size * 0.34))
        check.path = tick.cgPath
        check.strokeEnd = 0

        glyphContainer.layer.addSublayer(ring)
        glyphContainer.layer.addSublayer(check)
        ringLayer = ring
        checkLayer = check
    }

    /// The celebration: the ring strokes + pops in with a spring scale, then the tick
    /// strokes on. `completion` fires when the tick finishes.
    private func animateCheckmark(completion: @escaping () -> Void) {
        guard let ring = ringLayer, let check = checkLayer else { completion(); return }

        let ringDraw: CFTimeInterval = 0.32
        let tickDraw: CFTimeInterval = 0.30

        // Ring stroke-on.
        let ringStroke = CABasicAnimation(keyPath: "strokeEnd")
        ringStroke.fromValue = 0
        ringStroke.toValue = 1
        ringStroke.duration = ringDraw
        ringStroke.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.strokeEnd = 1
        ring.add(ringStroke, forKey: "ringStroke")

        // A subtle spring scale "pop" on the whole glyph square as the ring lands.
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.6
        pop.toValue = 1.0
        pop.damping = 9
        pop.stiffness = 170
        pop.mass = 0.7
        pop.initialVelocity = 6
        pop.duration = pop.settlingDuration
        glyphContainer.layer.add(pop, forKey: "pop")

        // Tick stroke-on, delayed until the ring is mostly drawn so it reads as a beat.
        let tickStroke = CABasicAnimation(keyPath: "strokeEnd")
        tickStroke.fromValue = 0
        tickStroke.toValue = 1
        tickStroke.duration = tickDraw
        tickStroke.beginTime = CACurrentMediaTime() + ringDraw * 0.7
        tickStroke.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        tickStroke.fillMode = .backwards
        check.strokeEnd = 1

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        check.add(tickStroke, forKey: "tickStroke")
        CATransaction.commit()
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
        // Downsampled decode (not the full-size `UIImage(contentsOfFile:)` this used
        // to do) — one card is shown at a time here, but a full-resolution cover photo
        // is still wasteful to hold decoded for a card-width well.
        if let fileName = item.thumbnailFileName,
           let image = ImageDownsampling.decode(
                path: store.articlesDirectory.appendingPathComponent(fileName).path,
                scale: UIScreen.main.scale, maxPixelSize: 1200) {
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

    /// A read-only solid (de-glassed, Task 3) pill mirroring `AlertThresholdSlider`'s
    /// chrome — the "Alert threshold" title and the SAME percent + absolute readout
    /// (`PriceFormatting.thresholdDescription`) — but with a "Change" button instead
    /// of the interactive slider, since catch-up is a glance surface (editing happens
    /// on the full price-tracking screen).
    private static func makeThresholdReadout(
        tracker: PriceTracker, onChange: @escaping () -> Void
    ) -> UIView {
        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = GlassStyle.solidBarColor
        pill.layer.cornerRadius = 22
        pill.layer.cornerCurve = .continuous
        pill.clipsToBounds = true

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
        pill.addSubview(copy)
        changeButton.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(changeButton)
        // Text on the left, a self-sized capsule "Change" button on the right, side by
        // side with a real gap — so the button is an unambiguous tap target and the
        // multi-line readout can never run underneath it.
        NSLayoutConstraint.activate([
            copy.topAnchor.constraint(equalTo: pill.topAnchor, constant: 12),
            copy.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            copy.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -12),
            changeButton.leadingAnchor.constraint(equalTo: copy.trailingAnchor, constant: 12),
            changeButton.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            changeButton.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        return pill
    }

    /// Resolves the tracker's product image the SAME way the reading-list cell does
    /// (`PriceTracker.imageFileName` inside the Articles directory), falling back to a
    /// `tag` glyph when there's no image — so the card shows the identical thumbnail.
    private static func configureThumbnail(
        _ imageView: UIImageView, tracker: PriceTracker, store: ReadingListStore
    ) {
        // Downsampled decode: the thumbnail well here is a fixed 64×64 point square,
        // so there's no reason to decode (and briefly hold) a full-size product photo.
        if let fileName = tracker.imageFileName,
           let image = ImageDownsampling.decode(
                path: store.articlesDirectory.appendingPathComponent(fileName).path,
                scale: UIScreen.main.scale, maxPixelSize: 64 * 2 * UIScreen.main.scale) {
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
