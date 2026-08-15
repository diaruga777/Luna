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
//  ONE strip, in every app. Each chip is a tiny card surface with the save's
//  source badge (favicon / sender initials / symbol) as a mini masthead over
//  skeleton text lines — a shrunken copy of the card above it. A chip whose
//  save is a PICTURE rather than text shows that still full-bleed instead.
//  Which of the two a chip is, is the CARD's answer (`prefersThumbnailChip`),
//  never the deck's: the Downloader's strip is this strip, with every chip
//  happening to be a still.
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
    /// this bounded window to request only the artwork that can be displayed.
    func scrubber(_ scrubber: CarouselScrubberView, didShow indices: IndexSet)
}

public extension CarouselScrubberViewDelegate {
    func scrubber(_ scrubber: CarouselScrubberView, didShow indices: IndexSet) {}
    func scrubber(_ scrubber: CarouselScrubberView, didTap index: Int) {
        self.scrubber(scrubber, didCommit: index)
    }
}

public final class CarouselScrubberView: UIView {

    public weak var delegate: CarouselScrubberViewDelegate?

    /// Width of the alpha-fade zone at each end of the strip. Chips dissolve
    /// across this zone as they approach the bounds, so flanking controls
    /// never sit over fully-drawn chips. 0 disables the effect.
    public var edgeFadeWidth: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    private var itemSize: CGSize { CGSize(width: 44, height: 64) }

    /// The selected mini-card scales to 1.1× and casts a 5pt shadow. Leave
    /// enough vertical runway for both instead of clipping the shadow against
    /// the scroll view's bottom edge.
    ///
    /// Static because it is one of the two chrome measurements that decide the
    /// card area, and `CardDeckGeometry` has to know it without a strip to ask.
    public static let preferredHeight: CGFloat = 64 + 32

    public var preferredHeight: CGFloat { Self.preferredHeight }

    /// At 1.1× the 44pt selected card is 48.4pt wide. A 12pt pitch gap keeps it
    /// visibly separate from both unselected neighbors.
    private var spacing: CGFloat { 12 }

    /// Hosts the scroll view and carries the edge fade mask. The mask must
    /// live on a non-scrolling ancestor (a mask on the scroll view's own layer
    /// would ride along with its scrolled bounds).
    private let stripContainer = UIView()
    private let layout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(
        frame: .zero, collectionViewLayout: layout)
    private let fadeMask = GradientMaskView()
    private var itemCount = 0
    private var selectedIndex = 0
    private var reportedVisibleIndices = IndexSet()
    private let selectionFeedback = UISelectionFeedbackGenerator()

    /// True while the strip's motion belongs to the user's finger (dragging or
    /// the deceleration it launched). Programmatic centering must stand aside,
    /// and only user-driven motion previews cards.
    private var isUserScrolling: Bool {
        collectionView.isDragging || collectionView.isDecelerating
    }

    public init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        stripContainer.frame = bounds
        stripContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(stripContainer)

        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = spacing
        layout.minimumInteritemSpacing = spacing

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        // Native scrolling IS the scrub interaction; the fast deceleration
        // rate plus the targetContentOffset snap settles a chip dead-center.
        collectionView.decelerationRate = .fast
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.register(
            ScrubberItemCell.self,
            forCellWithReuseIdentifier: ScrubberItemCell.reuseIdentifier)
        stripContainer.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: stripContainer.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: stripContainer.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: stripContainer.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: stripContainer.trailingAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tap)
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
        let sectionInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        guard layout.sectionInset != sectionInset else { return }
        layout.sectionInset = sectionInset
        layout.invalidateLayout()
    }

    private func layoutEdgeVeils() {
        stripContainer.layer.mask = edgeFadeWidth > 0 ? fadeMask.layer : nil
        fadeMask.frame = stripContainer.bounds
        fadeMask.setFadeWidth(edgeFadeWidth, in: bounds.width)
    }

    // MARK: - Content

    public func setThumbnailCount(_ count: Int) {
        itemCount = max(count, 0)
        selectedIndex = min(selectedIndex, max(0, count - 1))
        reportedVisibleIndices = []
        collectionView.reloadData()
        layoutIfNeeded()
        scrollSelectedToCenter(animated: false)
        reportVisibleIndicesIfNeeded()
    }

    /// The chip's picture. In `.thumbnails` it IS the chip; in `.miniCards` a
    /// non-nil image takes the whole chip, covering the mini card's badge and
    /// skeleton text, and nil restores them.
    public func setThumbnail(_ image: UIImage?, at index: Int) {
        itemView(at: index)?.setImage(image)
    }

    /// Source badge for a `.miniCards` chip. nil shows the neutral placeholder.
    /// Setting a badge also clears any full-bleed image the chip carried, so a
    /// recycled chip reverts from a media still to a mini card.
    public func setBadge(_ badge: CarouselSourceBadge?, at index: Int) {
        itemView(at: index)?.setImage(nil)
        itemView(at: index)?.setBadge(badge)
    }

    /// The permanent util card's chip. It is not a save, so it gets neither a
    /// favicon badge nor skeleton body text: the running app's own
    /// action-extension icon sits high on the chip with one pill beneath it
    /// standing in for the card's button — a shrunken copy of a card that holds
    /// a mark and a control rather than an article.
    public func setUtilityChip(icon: UIImage?, at index: Int) {
        itemView(at: index)?.setUtilityIcon(icon)
    }

    /// Artwork layered over a `.miniCards` chip without replacing its thumbnail.
    public func setAccessoryImage(_ image: UIImage?, at index: Int) {
        itemView(at: index)?.setAccessoryImage(image)
    }

    public func setSelectedIndex(_ index: Int, animated: Bool) {
        guard index >= 0, index < itemCount else { return }
        let oldIndex = selectedIndex
        selectedIndex = index
        applySelectionAppearance(from: oldIndex, to: index)
        // While the user is scrolling the strip, their finger (or its
        // momentum) owns the offset; the settle commit re-centers.
        if !isUserScrolling { scrollSelectedToCenter(animated: animated) }
    }

    /// Scrolls so the selected chip sits at the viewport's center. The
    /// symmetric content insets guarantee every chip can reach it exactly.
    private func scrollSelectedToCenter(animated: Bool) {
        guard let x = centeringOffsetX(forIndex: selectedIndex),
              abs(collectionView.contentOffset.x - x) > 0.5 else { return }
        collectionView.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
    }

    /// The content offset that puts chip `index`'s center at the viewport's
    /// center, or nil before layout can answer.
    private func centeringOffsetX(forIndex index: Int) -> CGFloat? {
        guard index >= 0, index < itemCount, collectionView.bounds.width > 0
        else { return nil }
        // Symmetric section insets put item zero at offset zero; every later
        // center is exactly one fixed pitch farther along.
        return CGFloat(index) * (itemSize.width + spacing)
    }

    private func applySelectionAppearance(from oldIndex: Int, to newIndex: Int) {
        guard oldIndex != newIndex else {
            itemView(at: newIndex)?.setSelected(true)
            return
        }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
            self.itemView(at: oldIndex)?.setSelected(false)
            self.itemView(at: newIndex)?.setSelected(true)
        }
    }

    private func itemView(at index: Int) -> ScrubberItemView? {
        guard index >= 0, index < itemCount else { return nil }
        return (collectionView.cellForItem(at: IndexPath(item: index, section: 0))
            as? ScrubberItemCell)?.itemView
    }

    // MARK: - Gestures

    private func index(atX x: CGFloat) -> Int {
        return CarouselScrubberMath.index(
            forLocationX: x - layout.sectionInset.left,
            thumbnailWidth: itemSize.width,
            spacing: spacing,
            count: itemCount)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard itemCount > 0 else { return }
        delegate?.scrubber(
            self, didTap: index(atX: gesture.location(in: collectionView).x))
    }

    /// The chip whose centered position is closest to content offset `x` —
    /// i.e. the chip at (or nearest) the viewport's center at that offset.
    private func nearestIndex(toOffsetX x: CGFloat) -> Int {
        guard itemCount > 0 else { return 0 }
        let pitch = itemSize.width + spacing
        let index = Int((x / pitch).rounded())
        return min(max(index, 0), itemCount - 1)
    }

    private func reportVisibleIndicesIfNeeded() {
        guard itemCount > 0, collectionView.bounds.width > 0 else { return }
        let pitch = itemSize.width + spacing
        let radius = Int(ceil(
            (collectionView.bounds.width / 2 + itemSize.width / 2) / pitch))
        let center = nearestIndex(toOffsetX: collectionView.contentOffset.x)
        let lower = max(0, center - radius)
        let upper = min(itemCount - 1, center + radius)
        let visible = IndexSet(integersIn: lower...upper)
        guard visible != reportedVisibleIndices else { return }
        reportedVisibleIndices = visible
        delegate?.scrubber(self, didShow: visible)
    }
}

// MARK: - Scroll-driven scrubbing

extension CarouselScrubberView: UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout {

    public func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int { itemCount }

    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ScrubberItemCell.reuseIdentifier,
            for: indexPath) as! ScrubberItemCell
        cell.itemView.reset()
        cell.itemView.setSelected(indexPath.item == selectedIndex)
        return cell
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize { itemSize }

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
        let oldIndex = selectedIndex
        selectedIndex = index
        applySelectionAppearance(from: oldIndex, to: index)
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
        guard itemCount > 0 else { return }
        delegate?.scrubber(
            self, didCommit: nearestIndex(toOffsetX: collectionView.contentOffset.x))
    }
}

private final class ScrubberItemCell: UICollectionViewCell {
    static let reuseIdentifier = "ScrubberItemCell"
    let itemView = ScrubberItemView(size: CGSize(width: 44, height: 64))

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(itemView)
        NSLayoutConstraint.activate([
            itemView.topAnchor.constraint(equalTo: contentView.topAnchor),
            itemView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            itemView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            itemView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        itemView.reset()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
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

/// One strip chip: a miniature card — a tiny surface with a source badge as
/// its masthead, two headline bars, and fainter body bars, so the chip reads as
/// a shrunken version of the card above it — or, when the save is a picture,
/// that picture full-bleed over the same surface. Selection reads as elevation — the
/// selected chip lifts with a soft shadow; its siblings recede — instead of a
/// drawn border.
private final class ScrubberItemView: UIView {
    /// The util chip's mark and its button pill, as fractions of the chip.
    private enum UtilityChipMetrics {
        /// The mark matches a mini card's source badge exactly — the util card
        /// carries an identity, not a picture.
        static let markSide: CGFloat = 16
        /// Vertically centered, then lifted by this factor: the mark reads as
        /// the card's masthead while leaving the pill room below it.
        static let markCenterLift: CGFloat = 1.3
        static let pillWidth: CGFloat = 24
        static let pillHeight: CGFloat = 8
        static let pillGap: CGFloat = 5
    }

    let imageView = UIImageView()
    private let badgeView = CarouselSourceBadgeView()
    private let accessoryImageView = UIImageView()
    /// The mini card's own furniture (badge + skeleton bars), hidden while the
    /// chip shows a full-bleed still instead.
    private var miniCardFurniture: [UIView] = []
    /// The util chip's own furniture, built on demand and laid out from bounds
    /// (the chip is sized by Auto Layout after init).
    private var utilityMark: UIImageView?
    private var utilityPill: UIView?

    init(size: CGSize) {
        super.init(frame: .zero)
        layer.cornerRadius = 9
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
        do {
            buildMiniCard(size: size)
            // Added over the mini card, not instead of it: a save with a still
            // covers the furniture, one without keeps showing it.
            installImageView(cornerRadius: 9)
            imageView.isHidden = true
            accessoryImageView.frame = CGRect(
                x: size.width - 25, y: size.height - 25, width: 20, height: 20)
            accessoryImageView.contentMode = .scaleAspectFit
            accessoryImageView.isUserInteractionEnabled = false
            accessoryImageView.layer.shadowColor = UIColor.black.cgColor
            accessoryImageView.layer.shadowOpacity = 0.45
            accessoryImageView.layer.shadowRadius = 2
            accessoryImageView.layer.shadowOffset = CGSize(width: 0, height: 1)
            addSubview(accessoryImageView)
        }
        setSelected(false)
    }

    private func installImageView(cornerRadius: CGFloat) {
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = cornerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.backgroundColor = LunaColors.tertiaryFill
        // This view is created before Auto Layout gives its parent `size`.
        // Starting at `size` and also using flexible width/height doubles
        // the image when the parent grows from zero to its constrained
        // bounds, making thumbnails overlap and clip below the strip.
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
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
        miniCardFurniture.append(badgeView)

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
        miniCardFurniture.append(bar)
    }

    func setBadge(_ badge: CarouselSourceBadge?) {
        badgeView.setBadge(badge)
    }

    /// Turns this chip into the util card's: a card surface carrying the app's
    /// action-extension mark and one button pill, and nothing else. Both a
    /// thumbnail well and a mini card's furniture stand down for it.
    func setUtilityIcon(_ icon: UIImage?) {
        backgroundColor = LunaColors.background
        imageView.image = nil
        imageView.isHidden = true
        for view in miniCardFurniture { view.isHidden = true }

        let mark = utilityMark ?? {
            let view = UIImageView()
            view.contentMode = .scaleAspectFit
            view.clipsToBounds = true
            view.layer.cornerRadius = 4
            view.layer.cornerCurve = .continuous
            view.isUserInteractionEnabled = false
            addSubview(view)
            utilityMark = view
            return view
        }()
        mark.image = icon
        if utilityPill == nil {
            let pill = UIView()
            pill.backgroundColor = LunaColors.fill
            pill.layer.cornerRadius = UtilityChipMetrics.pillHeight / 2
            pill.isUserInteractionEnabled = false
            addSubview(pill)
            utilityPill = pill
        }
        setNeedsLayout()
    }

    /// A chip handed ordinary save artwork stops being the util card's.
    private func discardUtilityFurniture() {
        guard utilityMark != nil || utilityPill != nil else { return }
        utilityMark?.removeFromSuperview()
        utilityPill?.removeFromSuperview()
        utilityMark = nil
        utilityPill = nil
        backgroundColor = LunaColors.background
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let mark = utilityMark, let pill = utilityPill else { return }
        let side = UtilityChipMetrics.markSide
        let centerY = bounds.height / 2 / UtilityChipMetrics.markCenterLift
        mark.frame = CGRect(
            x: ((bounds.width - side) / 2).rounded(),
            y: (centerY - side / 2).rounded(),
            width: side,
            height: side)
        pill.frame = CGRect(
            x: ((bounds.width - UtilityChipMetrics.pillWidth) / 2).rounded(),
            y: (mark.frame.maxY + UtilityChipMetrics.pillGap).rounded(),
            width: UtilityChipMetrics.pillWidth,
            height: UtilityChipMetrics.pillHeight)
    }

    /// The chip's picture. In `.miniCards` an image swaps the mini card's
    /// furniture out for a full-bleed still; nil brings the furniture back.
    func setImage(_ image: UIImage?) {
        discardUtilityFurniture()
        imageView.image = image
        imageView.isHidden = image == nil
        for view in miniCardFurniture { view.isHidden = image != nil }
    }

    func setAccessoryImage(_ image: UIImage?) {
        accessoryImageView.image = image
        accessoryImageView.isHidden = image == nil
        if image != nil { bringSubviewToFront(accessoryImageView) }
    }

    func reset() {
        setImage(nil)
        setBadge(nil)
        setAccessoryImage(nil)
        setSelected(false)
    }

    func setSelected(_ selected: Bool) {
        transform = selected ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity
        layer.shadowOpacity = selected ? 0.22 : 0
        // The whole mini card recedes when unselected (its shadow is already
        // off, so dimming the view itself is safe).
        alpha = selected ? 1 : 0.62
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
