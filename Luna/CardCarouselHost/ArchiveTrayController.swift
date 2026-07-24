//
//  ArchiveTrayController.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// Display-ready archive entry shared by the Reader and Downloader trays.
/// The hosts retain domain ownership; this type only describes presentation
/// and forwards user intent through closures.
struct ArchiveTrayItem {
    let id: UUID
    let title: String?
    let footer: String?
    let showsMetadata: Bool
    let isAvailable: Bool
    let loadImage: (@escaping (UIImage?) -> Void) -> Void
    let tap: () -> Void
    let share: (UIView) -> Void
    /// The pressed cell is supplied so a surface can animate the item back to
    /// its destination. Accessibility activation supplies the cell as well.
    let unarchive: (UIView) -> Void
    /// Surface-owned permanent deletion. Both surfaces supply their complete
    /// save-cleanup path.
    let delete: (() -> Void)?
}

/// Lays the archive cells (and the leading "archive" header cell) along a
/// circular arc whose pivot sits far off the screen's right edge, so the
/// column bows left. Scrolling stays ordinary vertical scrolling, but each
/// item's position and tilt derive from its arc-length distance to the
/// viewport's vertical midline — so the whole arc visibly rotates about the
/// offscreen pivot as it scrolls.
final class ArchiveArcLayout: UICollectionViewLayout {
    var itemSize = CGSize(width: 200, height: 128)
    var headerHeight: CGFloat = 40
    var spacing: CGFloat = 10
    var topInset: CGFloat = 18
    var bottomInset: CGFloat = 28
    /// Gap between the container's leading edge and the arc's apex (its
    /// leftmost cell). Kept small so the peeking closed state shows cell, not
    /// margin.
    var leadingInset: CGFloat = 8
    /// Distance from every cell to the offscreen pivot. Larger = flatter arc.
    var radius: CGFloat = 1_000

    /// Arc-length position of each item's center, top to bottom.
    private var arcCenters: [CGFloat] = []
    private var contentHeight: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        arcCenters.removeAll()
        var y = topInset
        for index in 0..<collectionView.numberOfItems(inSection: 0) {
            let height = index == 0 ? headerHeight : itemSize.height
            arcCenters.append(y + height / 2)
            y += height + spacing
        }
        contentHeight = arcCenters.isEmpty ? 0 : y - spacing + bottomInset
        // Content shorter than the viewport centers on the apex. Pinned to the
        // top it would ride the arc's upper sweep, drifting right — away from
        // the screen edge whose closed-state peek depends on it.
        let centering = (collectionView.bounds.height - contentHeight) / 2
        if centering > 0 {
            arcCenters = arcCenters.map { $0 + centering }
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    /// Every position depends on the scroll offset (the arc's rotation), so
    /// any bounds change must relayout.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForElements(
        in rect: CGRect
    ) -> [UICollectionViewLayoutAttributes]? {
        (0..<arcCenters.count)
            .compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
            .filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let collectionView, arcCenters.indices.contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.size = indexPath.item == 0
            ? CGSize(width: itemSize.width, height: headerHeight)
            : itemSize
        // The item's sweep angle away from the viewport midline (the apex).
        let viewportMid = collectionView.contentOffset.y + collectionView.bounds.height / 2
        let angle = (arcCenters[indexPath.item] - viewportMid) / max(radius, 1)
        let apexCenterX = leadingInset + itemSize.width / 2
        attributes.center = CGPoint(
            x: apexCenterX + radius * (1 - cos(angle)),
            y: viewportMid + radius * sin(angle))
        // Point each cell's long axis at the pivot, spoke-like. Negated
        // because UIKit's positive rotation is clockwise in its y-down space.
        attributes.transform = CGAffineTransform(rotationAngle: -angle)
        attributes.zIndex = indexPath.item
        return attributes
    }
}

/// A chrome-less drawer of archive cells arranged along a right-edge arc.
/// There is no tray background or pull tab — the cells are the entire
/// surface. Closed, the arc sits offscreen; while the host rests on its
/// rightmost card (or empty state) and the archive has items, the apex cells
/// peek in from the right edge. A leftward pull opens the arc over the right
/// two thirds of the screen while the current card/empty state translates
/// left by the same two thirds, ceding that space to the arc.
final class ArchiveTrayController: NSObject {
    private weak var host: UIViewController?
    private let shiftedViews: () -> [UIView]
    private let canPull: () -> Bool
    private let openStateChanged: (Bool) -> Void
    /// Invisible container that carries the arc's horizontal reveal. It still
    /// hit-tests, so an open arc blocks taps from reaching the shifted card.
    private let tray = UIView()
    private let dismissControl = UIControl()
    private let arcLayout = ArchiveArcLayout()
    private let collection: UICollectionView
    private var pan: UIPanGestureRecognizer!
    private var items: [ArchiveTrayItem] = []
    private var progress: CGFloat = 0
    private var panStartProgress: CGFloat = 0
    private var laidOutSize = CGSize.zero
    /// The closed arc is wholly offscreen until its host reaches the rightmost
    /// card. Changing this state slides the apex cells' peek into view.
    private var pullAvailable = false
    /// Mirrors the card chrome: while the reader is immersed the peek fades
    /// out with the side-card peeks (and the pull is disabled), fading back
    /// when the chrome returns.
    private var chromeHidden = false

    /// How far the apex cells poke past the screen edge while closed-but-
    /// available. Wider than the old pull tab's 13pt because what peeks now is
    /// the cells themselves.
    private static let peek: CGFloat = 26

    init(
        host: UIViewController,
        shiftedViews: @escaping () -> [UIView],
        canPull: @escaping () -> Bool,
        openStateChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.host = host
        self.shiftedViews = shiftedViews
        self.canPull = canPull
        self.openStateChanged = openStateChanged
        collection = UICollectionView(frame: .zero, collectionViewLayout: arcLayout)
        super.init()
        configure()
    }

    private func configure() {
        guard let view = host?.view else { return }
        dismissControl.backgroundColor = .clear
        dismissControl.alpha = 0
        dismissControl.isHidden = true
        dismissControl.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        view.addSubview(dismissControl)

        tray.backgroundColor = .clear
        view.addSubview(tray)

        collection.backgroundColor = .clear
        collection.alwaysBounceVertical = true
        collection.showsVerticalScrollIndicator = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(ArchiveTrayCell.self, forCellWithReuseIdentifier: ArchiveTrayCell.reuseID)
        collection.register(
            ArchiveArcHeaderCell.self, forCellWithReuseIdentifier: ArchiveArcHeaderCell.reuseID)
        tray.addSubview(collection)

        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    func setItems(_ items: [ArchiveTrayItem]) {
        self.items = items
        collection.reloadData()
        // The closed peek exists only when there are cells to peek, so a
        // change in emptiness repositions the closed arc.
        applyProgress()
    }

    /// Re-evaluates the host's right-edge condition. Paging onto the last card
    /// animates the closed arc from fully offscreen to its cell peek; paging
    /// away retracts it and closes an open arc defensively.
    func refreshPullAvailability(animated: Bool) {
        setPullAvailable(canPull(), animated: animated)
    }

    /// Closes an open arc. Surface-owned item transitions use this to keep the
    /// drawer dismissal in lockstep with their own animation.
    func dismiss(animated: Bool) {
        setOpen(false, animated: animated)
    }

    /// Updates availability from an in-flight carousel target. This does not
    /// consult `canPull`, whose current-index answer intentionally lags until
    /// the card transition reaches its swap point.
    func setPullAvailable(_ available: Bool, animated: Bool) {
        guard available != pullAvailable else { return }
        pullAvailable = available
        if !available { progress = 0 }
        let changes = { self.applyProgress() }
        if animated, laidOutSize.width > 0, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.32, delay: 0,
                usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
        } else {
            changes()
        }
    }

    /// Fades the arc in lockstep with the card chrome — the same 0.32s
    /// ease-in-out the carousel uses for its side-card peeks and scrub strip.
    /// Hiding an open arc closes it first so the shifted card is never left
    /// stranded behind an invisible drawer.
    func setChromeHidden(_ hidden: Bool, animated: Bool) {
        guard hidden != chromeHidden else { return }
        chromeHidden = hidden
        if hidden, progress > 0.001 { setOpen(false, animated: animated) }
        let changes = { self.tray.alpha = hidden ? 0 : 1 }
        if animated {
            UIView.animate(
                withDuration: 0.32, delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
                animations: changes)
        } else {
            changes()
        }
    }

    func layout(in bounds: CGRect, safeAreaInsets: UIEdgeInsets) {
        guard bounds.size.width > 0 else { return }
        let isFirstLayout = laidOutSize == .zero
        laidOutSize = bounds.size
        if isFirstLayout { pullAvailable = canPull() }
        dismissControl.frame = bounds
        let width = bounds.width * 2 / 3
        let top = safeAreaInsets.top + 8
        let bottom = safeAreaInsets.bottom + 8
        tray.bounds = CGRect(x: 0, y: 0, width: width, height: max(0, bounds.height - top - bottom))
        tray.center.y = top + tray.bounds.height / 2
        collection.frame = tray.bounds
        // Narrower than the old full-width rows: the trailing slack is what
        // lets off-apex cells drift rightward along the arc without leaving
        // the screen immediately.
        arcLayout.itemSize = CGSize(width: max(0, floor(width) - 56), height: 128)
        arcLayout.radius = max(tray.bounds.height, 400) * 1.4
        arcLayout.invalidateLayout()
        applyProgress()
    }

    @objc private func dismissTapped() { setOpen(false, animated: true) }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard laidOutSize.width > 0 else { return }
        switch gesture.state {
        case .began:
            panStartProgress = progress
        case .changed:
            let travel = max(1, laidOutSize.width * 2 / 3 - Self.peek)
            progress = min(max(panStartProgress - gesture.translation(in: host?.view).x / travel, 0), 1)
            applyProgress()
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: host?.view).x
            setOpen(velocity < -220 || (velocity <= 220 && progress >= 0.42), animated: true)
        default:
            break
        }
    }

    private func setOpen(_ open: Bool, animated: Bool) {
        progress = open ? 1 : 0
        let changes = { self.applyProgress() }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.36, delay: 0,
                usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
        } else {
            changes()
        }
    }

    private func applyProgress() {
        guard laidOutSize.width > 0 else { return }
        let width = laidOutSize.width * 2 / 3
        // Closed, the arc is wholly offscreen — unless the rightmost card is
        // centered AND the archive has items, when the apex cells peek in
        // where the old pull tab used to.
        let closedX = pullAvailable && !items.isEmpty
            ? laidOutSize.width - Self.peek
            : laidOutSize.width
        let openX = laidOutSize.width - width
        tray.frame.origin.x = closedX + (openX - closedX) * progress
        // The card (or empty state) clears the arc's full region.
        let shift = -laidOutSize.width * 2 / 3 * progress
        shiftedViews().forEach { $0.transform = CGAffineTransform(translationX: shift, y: 0) }
        openStateChanged(progress > 0.001)
        dismissControl.isHidden = progress < 0.01
        dismissControl.alpha = progress * 0.18
    }

    #if DEBUG
    var isPullAvailableForTesting: Bool { pullAvailable }
    var trayFrameForTesting: CGRect { tray.frame }
    var trayAlphaForTesting: CGFloat { tray.alpha }
    var itemSizeForTesting: CGSize { arcLayout.itemSize }
    var arcLayoutForTesting: ArchiveArcLayout { arcLayout }
    var headerTitleForTesting: String { ArchiveArcHeaderCell.title }
    func contextMenuForTesting(itemAt index: Int) -> UIMenu {
        contextMenu(for: items[index], sourceView: collection)
    }
    func setOpenForTesting(_ open: Bool) { setOpen(open, animated: false) }
    #endif
}

extension ArchiveTrayController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        // An invisible (chrome-hidden) arc must not be pullable.
        guard !chromeHidden else { return false }
        let velocity = pan.velocity(in: host?.view)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        // An empty archive has nothing to reveal — never start a new pull for
        // one (there's no empty state to show). An already-open arc can still
        // finish its interaction defensively.
        return progress > 0 || (velocity.x < 0 && !items.isEmpty && canPull())
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }
}

extension ArchiveTrayController: UICollectionViewDataSource, UICollectionViewDelegate {
    /// Item 0 is always the "archive" header cell; archive entries follow.
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count + 1
    }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if indexPath.item == 0 {
            return collectionView.dequeueReusableCell(
                withReuseIdentifier: ArchiveArcHeaderCell.reuseID, for: indexPath)
        }
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ArchiveTrayCell.reuseID, for: indexPath) as! ArchiveTrayCell
        cell.configure(with: items[indexPath.item - 1])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item > 0 else { return }
        items[indexPath.item - 1].tap()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPath.item > 0 else { return nil }
        let item = items[indexPath.item - 1]
        let sourceView = collectionView.cellForItem(at: indexPath) ?? collectionView
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            self?.contextMenu(for: item, sourceView: sourceView)
        })
    }

    private func contextMenu(for item: ArchiveTrayItem, sourceView: UIView) -> UIMenu {
        var actions: [UIAction] = [
            UIAction(
                title: "Unarchive", image: UIImage(systemName: "tray.and.arrow.up")
            ) { _ in item.unarchive(sourceView) },
            UIAction(
                title: "Share", image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in item.share(sourceView) },
        ]
        if let delete = item.delete {
            actions.append(UIAction(
                title: "Delete", image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in delete() })
        }
        return UIMenu(children: actions)
    }

}

/// The arc's leading cell: the pane's "archive" title, positioned and tilted
/// by the same arc math as the item cells so it scrolls with them.
private final class ArchiveArcHeaderCell: UICollectionViewCell {
    static let reuseID = "ArchiveArcHeaderCell"
    static let title = "archive"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .header
        accessibilityLabel = "Archive"
        label.text = Self.title
        label.font = UIFontMetrics(forTextStyle: .title3)
            .scaledFont(for: .systemFont(ofSize: 20, weight: .semibold))
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.72
        label.textColor = LunaColors.primaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class ArchiveTrayCell: UICollectionViewCell {
    static let reuseID = "ArchiveTrayCell"
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let footerLabel = UILabel()
    private let unavailableIcon = UIImageView(image: UIImage(systemName: "arrow.down.circle.dotted"))
    private var imageCompactConstraint: NSLayoutConstraint!
    private var imageFillConstraint: NSLayoutConstraint!
    private var representedID: UUID?
    private var unarchive: ((UIView) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        contentView.backgroundColor = LunaColors.tertiaryBackground
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.numberOfLines = 3
        footerLabel.font = .preferredFont(forTextStyle: .caption2)
        footerLabel.textColor = LunaColors.secondaryText
        unavailableIcon.tintColor = LunaColors.primaryText
        unavailableIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 25)
        for child in [imageView, titleLabel, footerLabel, unavailableIcon] {
            child.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(child)
        }
        imageCompactConstraint = imageView.widthAnchor.constraint(
            equalTo: contentView.widthAnchor, multiplier: 0.42)
        imageFillConstraint = imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageCompactConstraint,
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            footerLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            footerLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            footerLabel.topAnchor.constraint(greaterThanOrEqualTo: titleLabel.bottomAnchor, constant: 4),
            footerLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            unavailableIcon.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            unavailableIcon.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        representedID = nil
        unarchive = nil
        accessibilityCustomActions = nil
        imageView.image = nil
        super.prepareForReuse()
    }

    func configure(with item: ArchiveTrayItem) {
        representedID = item.id
        unarchive = item.unarchive
        titleLabel.text = item.title
        footerLabel.text = item.footer
        imageCompactConstraint.isActive = item.showsMetadata
        imageFillConstraint.isActive = !item.showsMetadata
        titleLabel.isHidden = !item.showsMetadata
        footerLabel.isHidden = !item.showsMetadata
        unavailableIcon.isHidden = item.isAvailable
        contentView.alpha = item.isAvailable ? 1 : 0.64
        accessibilityLabel = [item.title, item.footer].compactMap { $0 }.joined(separator: ", ")
        accessibilityHint = item.isAvailable ? "Opens item" : "Downloads item"
        accessibilityCustomActions = [UIAccessibilityCustomAction(
            name: "Unarchive", target: self,
            selector: #selector(performAccessibilityUnarchive))]
        item.loadImage { [weak self] image in
            DispatchQueue.main.async {
                guard self?.representedID == item.id else { return }
                self?.imageView.image = image
            }
        }
    }

    @objc private func performAccessibilityUnarchive() -> Bool {
        guard let unarchive else { return false }
        unarchive(self)
        return true
    }
}
