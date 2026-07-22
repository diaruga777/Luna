//
//  CarouselScrubberView.swift
//  LunaDesignSystem
//
//  The scrub area under the cards: one small preview per card, scrolled like a
//  miniature carousel. The chip at the viewport's CENTER is the selection —
//  panning the strip scrolls it natively (finger moving left brings chips, and
//  thus cards, in from the right), and every chip that passes center previews
//  its card live. Symmetric content insets let even the first and last chips
//  reach center; releasing decelerates to the nearest chip dead-center
//  (snapped via targetContentOffset) and commits it. Taps commit the tapped
//  chip directly.
//
//  The strip has no container chrome — chips float directly on the background
//  and alpha-fade as they approach either end, so hosts can flank the strip
//  with controls and let chips disappear without drawing an edge veil.
//
//  Two styles: `.thumbnails` (small 9:16 image chips — Downloader) and
//  `.miniCards` (miniature article cards — Reader): each chip is a tiny card
//  surface with the save's source badge (favicon / sender initials / symbol)
//  as a mini masthead over skeleton text lines.
//

import UIKit

/// Reports the scrub strip's live preview and its settled commit. Sole
/// conformer is the owning `CardCarouselViewController`.
public protocol CarouselScrubberViewDelegate: AnyObject {
    /// A new chip reached the strip's center while the user scrolls it.
    func scrubber(_ scrubber: CarouselScrubberView, didPreview index: Int)
    /// The strip settled after user-driven scrolling: commit this index.
    func scrubber(_ scrubber: CarouselScrubberView, didCommit index: Int)
    /// A chip was tapped directly. Kept distinct from a scroll-settle commit so
    /// the carousel can animate the card change instead of promoting the live
    /// scrub preview.
    func scrubber(_ scrubber: CarouselScrubberView, didTap index: Int)
    /// The chips intersecting the scroll viewport changed. The carousel uses
    /// this bounded window to prepare exact card content for live previews.
    func scrubber(_ scrubber: CarouselScrubberView, didShow indices: IndexSet)
}

public extension CarouselScrubberViewDelegate {
    func scrubber(_ scrubber: CarouselScrubberView, didShow indices: IndexSet) {}
    func scrubber(_ scrubber: CarouselScrubberView, didTap index: Int) {
        self.scrubber(scrubber, didCommit: index)
    }
}

public final class CarouselScrubberView: UIView {

    /// What each strip item shows.
    public enum Style {
        /// Small 9:16 image chips (media thumbnails).
        case thumbnails
        /// Miniature article cards: a source badge over skeleton text lines.
        case miniCards

        var animateScrubTransitions: Bool {
            switch self {
            case .thumbnails: return false
            case .miniCards: return true
            }
        }
    }

    public weak var delegate: CarouselScrubberViewDelegate?

    public let style: Style

    /// Width of the alpha-fade zone at each end of the strip. Chips dissolve
    /// across this zone as they approach the bounds, so flanking controls
    /// never sit over fully-drawn chips. 0 disables the effect.
    public var edgeFadeWidth: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    private var itemSize: CGSize {
        switch style {
        case .thumbnails:
            return CGSize(width: 46 * CardCarouselMetrics.cardAspectRatio, height: 46)
        case .miniCards:
            return CGSize(width: 44, height: 64)
        }
    }

    public var preferredHeight: CGFloat {
        switch style {
        case .thumbnails:
            itemSize.height + 22
        case .miniCards:
            // The selected mini-card scales to 1.1× and casts a 5pt shadow.
            // Leave enough vertical runway for both instead of clipping the
            // shadow against the scroll view's bottom edge.
            itemSize.height + 32
        }
    }

    private var spacing: CGFloat {
        switch style {
        case .thumbnails:
            20
        case .miniCards:
            // At 1.1× the 44pt selected card is 48.4pt wide. A 12pt pitch gap
            // keeps it visibly separate from both unselected neighbors.
            12
        }
    }

    /// Hosts the scroll view and carries the edge fade mask. The mask must
    /// live on a non-scrolling ancestor (a mask on the scroll view's own layer
    /// would ride along with its scrolled bounds).
    private let stripContainer = UIView()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let fadeMask = GradientMaskView()
    private var itemViews: [ScrubberItemView] = []
    private var selectedIndex = 0
    private var reportedVisibleIndices = IndexSet()
    private let selectionFeedback = UISelectionFeedbackGenerator()

    /// True while the strip's motion belongs to the user's finger (dragging or
    /// the deceleration it launched). Programmatic centering must stand aside,
    /// and only user-driven motion previews cards.
    private var isUserScrolling: Bool {
        scrollView.isDragging || scrollView.isDecelerating
    }

    public init(style: Style = .thumbnails) {
        self.style = style
        super.init(frame: .zero)
        backgroundColor = .clear

        stripContainer.frame = bounds
        stripContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(stripContainer)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // Native scrolling IS the scrub interaction; the fast deceleration
        // rate plus the targetContentOffset snap settles a chip dead-center.
        scrollView.decelerationRate = .fast
        scrollView.delegate = self
        stripContainer.addSubview(scrollView)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: stripContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: stripContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: stripContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: stripContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

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
        updateContentInsets()
        if !isUserScrolling { scrollSelectedToCenter(animated: false) }
        layoutEdgeVeils()
        reportVisibleIndicesIfNeeded()
    }

    /// Symmetric insets of (viewport − chip) / 2 let EVERY chip — including
    /// the first and last — sit exactly at the viewport's center.
    private func updateContentInsets() {
        let inset = max(0, (bounds.width - itemSize.width) / 2)
        scrollView.contentInset.left = inset
        scrollView.contentInset.right = inset
    }

    private func layoutEdgeVeils() {
        stripContainer.layer.mask = edgeFadeWidth > 0 ? fadeMask.layer : nil
        fadeMask.frame = stripContainer.bounds
        fadeMask.setFadeWidth(edgeFadeWidth, in: bounds.width)
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
        layoutIfNeeded()
        reportVisibleIndicesIfNeeded()
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
        // While the user is scrolling the strip, their finger (or its
        // momentum) owns the offset; the settle commit re-centers.
        if !isUserScrolling { scrollSelectedToCenter(animated: animated) }
    }

    /// Scrolls so the selected chip sits at the viewport's center. The
    /// symmetric content insets guarantee every chip can reach it exactly.
    private func scrollSelectedToCenter(animated: Bool) {
        guard let x = centeringOffsetX(forIndex: selectedIndex),
              abs(scrollView.contentOffset.x - x) > 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
    }

    /// The content offset that puts chip `index`'s center at the viewport's
    /// center, or nil before layout can answer.
    private func centeringOffsetX(forIndex index: Int) -> CGFloat? {
        guard itemViews.indices.contains(index), scrollView.bounds.width > 0
        else { return nil }
        let target = itemViews[index]
        let chipCenterX = target.convert(
            CGPoint(x: target.bounds.midX, y: 0), to: scrollView).x
        return chipCenterX - scrollView.bounds.width / 2
    }

    private func applySelectionAppearance() {
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
            for (index, view) in self.itemViews.enumerated() {
                view.setSelected(index == self.selectedIndex)
            }
        }
    }

    // MARK: - Gestures

    private func index(atX x: CGFloat) -> Int {
        let inStrip = convert(CGPoint(x: x, y: 0), to: stack)
        return CarouselScrubberMath.index(
            forLocationX: inStrip.x,
            thumbnailWidth: itemSize.width,
            spacing: spacing,
            count: itemViews.count)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !itemViews.isEmpty else { return }
        delegate?.scrubber(self, didTap: index(atX: gesture.location(in: self).x))
    }

    /// The chip whose centered position is closest to content offset `x` —
    /// i.e. the chip at (or nearest) the viewport's center at that offset.
    private func nearestIndex(toOffsetX x: CGFloat) -> Int {
        guard !itemViews.isEmpty else { return 0 }
        let pitch = itemSize.width + spacing
        // Chip i sits centered at offset i·pitch − leftInset (see
        // updateContentInsets), so invert and round to the nearest chip.
        let index = Int(((x + scrollView.contentInset.left) / pitch).rounded())
        return min(max(index, 0), itemViews.count - 1)
    }

    private func reportVisibleIndicesIfNeeded() {
        guard !itemViews.isEmpty, scrollView.bounds.width > 0 else { return }
        let pitch = itemSize.width + spacing
        let radius = Int(ceil(
            (scrollView.bounds.width / 2 + itemSize.width / 2) / pitch))
        let center = nearestIndex(toOffsetX: scrollView.contentOffset.x)
        let lower = max(0, center - radius)
        let upper = min(itemViews.count - 1, center + radius)
        let visible = IndexSet(integersIn: lower...upper)
        guard visible != reportedVisibleIndices else { return }
        reportedVisibleIndices = visible
        delegate?.scrubber(self, didShow: visible)
    }
}

// MARK: - Scroll-driven scrubbing

extension CarouselScrubberView: UIScrollViewDelegate {

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        selectionFeedback.prepare()
    }

    /// Live preview: while the user scrolls the strip, every chip that passes
    /// the viewport's center becomes the selection (and previews its card).
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportVisibleIndicesIfNeeded()
        guard isUserScrolling else { return }
        let index = nearestIndex(toOffsetX: scrollView.contentOffset.x)
        guard index != selectedIndex else { return }
        selectedIndex = index
        applySelectionAppearance()
        selectionFeedback.selectionChanged()
        selectionFeedback.prepare()
        delegate?.scrubber(self, didPreview: index)
    }

    /// Snap: retarget the natural deceleration so it lands with the nearest
    /// chip (momentum included) dead-center — including the first and last
    /// chips, whose centered offsets are the scrollable range's ends.
    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let index = nearestIndex(toOffsetX: targetContentOffset.pointee.x)
        guard let x = centeringOffsetX(forIndex: index) else { return }
        targetContentOffset.pointee.x = x
    }

    public func scrollViewDidEndDragging(
        _ scrollView: UIScrollView, willDecelerate decelerate: Bool
    ) {
        if !decelerate { commitCenteredChip() }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        commitCenteredChip()
    }

    /// The strip settled: commit whichever chip ended up at center.
    private func commitCenteredChip() {
        guard !itemViews.isEmpty else { return }
        delegate?.scrubber(self, didCommit: nearestIndex(toOffsetX: scrollView.contentOffset.x))
    }
}

/// A view whose layer is a horizontal alpha gradient used as the strip's
/// non-scrolling outer fade mask.
private final class GradientMaskView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    private var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

    /// Full-strip mask: opaque through the middle, fading to clear across
    /// `fadeWidth` at both ends. Configure via `setFadeWidth`.
    override init(frame: CGRect) {
        super.init(frame: frame)
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.colors = [
            UIColor.clear.cgColor, UIColor.black.cgColor,
            UIColor.black.cgColor, UIColor.clear.cgColor,
        ]
        gradientLayer.locations = [0, 0, 1, 1]
    }

    func setFadeWidth(_ fadeWidth: CGFloat, in totalWidth: CGFloat) {
        guard totalWidth > 0 else { return }
        let fraction = min(max(fadeWidth / totalWidth, 0), 0.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.locations = [
            0, NSNumber(value: Double(fraction)),
            NSNumber(value: Double(1 - fraction)), 1,
        ]
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
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
            imageView.backgroundColor = LunaColors.tertiaryFill
            // This view is created before Auto Layout gives its parent `size`.
            // Starting at `size` and also using flexible width/height doubles
            // the image when the parent grows from zero to its constrained
            // bounds, making thumbnails overlap and clip below the strip.
            imageView.frame = bounds
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
        // so unselected chips still read as tiny cards floating on the
        // background.
        backgroundColor = LunaColors.background
        let inset: CGFloat = 6
        let contentWidth = size.width - inset * 2

        badgeView.frame = CGRect(x: inset, y: inset, width: 16, height: 16)
        addSubview(badgeView)

        addBar(x: inset, y: 28, width: contentWidth, height: 4, color: LunaColors.fill)
        addBar(x: inset, y: 35, width: contentWidth * 0.72, height: 4, color: LunaColors.fill)
        addBar(x: inset, y: 45, width: contentWidth, height: 3, color: LunaColors.tertiaryFill)
        addBar(x: inset, y: 51, width: contentWidth, height: 3, color: LunaColors.tertiaryFill)
        addBar(x: inset, y: 57, width: contentWidth * 0.6, height: 3, color: LunaColors.tertiaryFill)
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
