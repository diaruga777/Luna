//
//  CarouselScrubberView.swift
//  LunaDesignSystem
//
//  The scrub area under the cards: one small preview per card. Dragging through
//  it previews cards continuously (much faster than paging one by one);
//  releasing commits the index under the finger. A quick flick instead pages a
//  single card. The strip scrolls itself to keep the selection visible when
//  there are more previews than fit.
//
//  Two styles: `.thumbnails` (small 9:16 image chips — Downloader) and
//  `.miniCards` (miniature article cards — Reader): each chip is a tiny card
//  surface with the save's source badge (favicon / sender initials / symbol)
//  as a mini masthead over skeleton text lines.
//

import UIKit

public final class CarouselScrubberView: UIView {

    /// What each strip item shows.
    public enum Style {
        /// Small 9:16 image chips (media thumbnails).
        case thumbnails
        /// Miniature article cards: a source badge over skeleton text lines.
        case miniCards
    }

    /// Continuous callback while a positional drag moves over the strip.
    public var onPreview: ((Int) -> Void)?
    /// The finger lifted after a positional drag (or a tap): commit this index.
    public var onCommit: ((Int) -> Void)?
    /// A quick flick: page by ±1.
    public var onPageStep: ((Int) -> Void)?

    public let style: Style

    private var itemSize: CGSize {
        switch style {
        case .thumbnails:
            return CGSize(width: 46 * CardCarouselMetrics.cardAspectRatio, height: 46)
        case .miniCards:
            return CGSize(width: 44, height: 64)
        }
    }

    public var preferredHeight: CGFloat {
        itemSize.height + 22
    }

    private let spacing: CGFloat = 5

    private let tray = UIView()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var itemViews: [ScrubberItemView] = []
    private var selectedIndex = 0
    private var dragStartTime: CFTimeInterval = 0

    public init(style: Style = .thumbnails) {
        self.style = style
        super.init(frame: .zero)
        backgroundColor = .clear

        // A soft capsule tray hugs the strip, so the chips read as one control
        // instead of loose rectangles floating on the background.
        tray.backgroundColor = .secondarySystemBackground
        tray.layer.cornerCurve = .continuous
        tray.isUserInteractionEnabled = false
        addSubview(tray)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // The strip's own gestures do all the work; the scroll view is only a
        // programmatically-scrolled viewport.
        scrollView.panGestureRecognizer.isEnabled = false
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        centerStripIfNarrow()
        // The tray hugs the visible strip (content width when it fits, the
        // full viewport when it scrolls), with breathing room around the chips.
        let contentWidth = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        let trayWidth = min(bounds.width, contentWidth + 24)
        let trayHeight = itemSize.height + 16
        tray.frame = CGRect(
            x: (bounds.width - trayWidth) / 2,
            y: (bounds.height - trayHeight) / 2,
            width: trayWidth,
            height: trayHeight)
        tray.layer.cornerRadius = trayHeight / 2
    }

    /// When every item fits, center the strip instead of leading-aligning it.
    private func centerStripIfNarrow() {
        let contentWidth = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        let slack = bounds.width - contentWidth
        scrollView.contentInset.left = max(0, slack / 2)
    }

    // MARK: - Content

    public func setThumbnailCount(_ count: Int) {
        while itemViews.count > count {
            let view = itemViews.removeLast()
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        while itemViews.count < count {
            let view = ScrubberItemView(style: style, size: itemSize)
            stack.addArrangedSubview(view)
            itemViews.append(view)
        }
        selectedIndex = min(selectedIndex, max(0, count - 1))
        applySelectionAppearance()
        setNeedsLayout()
    }

    public func setThumbnail(_ image: UIImage?, at index: Int) {
        guard itemViews.indices.contains(index) else { return }
        itemViews[index].imageView.image = image
    }

    /// Source badge for a `.miniCards` chip. nil shows the neutral placeholder.
    public func setBadge(_ badge: CarouselSourceBadge?, at index: Int) {
        guard itemViews.indices.contains(index) else { return }
        itemViews[index].setBadge(badge)
    }

    public func setSelectedIndex(_ index: Int, animated: Bool) {
        guard itemViews.indices.contains(index) else { return }
        selectedIndex = index
        applySelectionAppearance()
        let target = itemViews[index]
        let frame = target.convert(target.bounds, to: scrollView).insetBy(dx: -30, dy: 0)
        scrollView.scrollRectToVisible(frame, animated: animated)
    }

    private func applySelectionAppearance() {
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
            for (index, view) in self.itemViews.enumerated() {
                view.setSelected(index == self.selectedIndex)
            }
        }
    }

    // MARK: - Gestures

    private func index(at location: CGPoint) -> Int {
        let inStrip = convert(location, to: stack)
        return CarouselScrubberMath.index(
            forLocationX: inStrip.x,
            thumbnailWidth: itemSize.width,
            spacing: spacing,
            count: itemViews.count)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !itemViews.isEmpty else { return }
        onCommit?(index(at: gesture.location(in: self)))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !itemViews.isEmpty else { return }
        switch gesture.state {
        case .began:
            dragStartTime = CACurrentMediaTime()
            preview(at: gesture.location(in: self))
        case .changed:
            preview(at: gesture.location(in: self))
        case .ended:
            let duration = CACurrentMediaTime() - dragStartTime
            if let step = CarouselScrubberMath.flickPageStep(
                translationX: gesture.translation(in: self).x,
                velocityX: gesture.velocity(in: self).x,
                duration: duration
            ) {
                onPageStep?(step)
            } else {
                onCommit?(index(at: gesture.location(in: self)))
            }
        case .cancelled, .failed:
            onCommit?(selectedIndex)
        default:
            break
        }
    }

    private func preview(at location: CGPoint) {
        let index = index(at: location)
        guard index != selectedIndex else { return }
        setSelectedIndex(index, animated: true)
        onPreview?(index)
    }
}

/// One strip chip: an image (thumbnail style) or a miniature article card
/// (mini-cards style) — a tiny card surface with a source badge as its
/// masthead, two headline bars, and fainter body bars, so the chip reads as a
/// shrunken version of the card above it. Selection reads as elevation — the
/// selected chip lifts with a soft shadow; its siblings recede — instead of a
/// drawn border.
private final class ScrubberItemView: UIView {
    let imageView = UIImageView()
    private let badgeView = CarouselSourceBadgeView()
    private let style: CarouselScrubberView.Style

    init(style: CarouselScrubberView.Style, size: CGSize) {
        self.style = style
        super.init(frame: .zero)
        layer.cornerRadius = style == .miniCards ? 9 : 6
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 5
        layer.shadowOpacity = 0
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
        switch style {
        case .thumbnails:
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 6
            imageView.layer.cornerCurve = .continuous
            imageView.backgroundColor = .tertiarySystemFill
            imageView.frame = CGRect(origin: .zero, size: size)
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(imageView)
        case .miniCards:
            buildMiniCard(size: size)
        }
        setSelected(false)
    }

    /// The mini-card layout mirrors a reader card in miniature: source badge
    /// top-leading (the masthead), two "headline" bars, then three fainter
    /// "body text" bars. Fixed geometry — the chip size never changes.
    private func buildMiniCard(size: CGSize) {
        // The chip carries its own card surface even when the shadow is off,
        // so unselected chips still read as tiny cards resting on the tray.
        backgroundColor = .systemBackground
        let inset: CGFloat = 6
        let contentWidth = size.width - inset * 2

        badgeView.frame = CGRect(x: inset, y: inset, width: 16, height: 16)
        addSubview(badgeView)

        addBar(x: inset, y: 28, width: contentWidth, height: 4, color: .systemFill)
        addBar(x: inset, y: 35, width: contentWidth * 0.72, height: 4, color: .systemFill)
        addBar(x: inset, y: 45, width: contentWidth, height: 3, color: .tertiarySystemFill)
        addBar(x: inset, y: 51, width: contentWidth, height: 3, color: .tertiarySystemFill)
        addBar(x: inset, y: 57, width: contentWidth * 0.6, height: 3, color: .tertiarySystemFill)
    }

    private func addBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, color: UIColor) {
        let bar = UIView(frame: CGRect(x: x, y: y, width: width, height: height))
        bar.backgroundColor = color
        bar.layer.cornerRadius = height / 2
        bar.isUserInteractionEnabled = false
        addSubview(bar)
    }

    func setBadge(_ badge: CarouselSourceBadge?) {
        badgeView.setBadge(badge)
    }

    func setSelected(_ selected: Bool) {
        transform = selected ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity
        layer.shadowOpacity = selected ? 0.22 : 0
        switch style {
        case .thumbnails:
            imageView.alpha = selected ? 1 : 0.55
        case .miniCards:
            // The whole mini card recedes when unselected (its shadow is
            // already off, so dimming the view itself is safe).
            alpha = selected ? 1 : 0.62
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
