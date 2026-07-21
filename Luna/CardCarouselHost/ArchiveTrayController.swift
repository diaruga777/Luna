//
//  ArchiveTrayController.swift
//  Luna
//

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
    let unarchive: () -> Void
}

/// A non-carousel drawer that peeks from the right edge and opens to two thirds
/// of the screen. Its pan moves the current card/empty state only half a screen,
/// leaving the tray visually independent from carousel paging.
final class ArchiveTrayController: NSObject {
    private weak var host: UIViewController?
    private let shiftedViews: () -> [UIView]
    private let canPull: () -> Bool
    private let tray = UIView()
    private let tab = UILabel()
    private let dismissControl = UIControl()
    private let collection: UICollectionView
    private let emptyLabel = UILabel()
    private var pan: UIPanGestureRecognizer!
    private var items: [ArchiveTrayItem] = []
    private var progress: CGFloat = 0
    private var panStartProgress: CGFloat = 0
    private var laidOutSize = CGSize.zero

    private static let peek: CGFloat = 13
    private static let tabWidth: CGFloat = 30

    init(host: UIViewController, shiftedViews: @escaping () -> [UIView], canPull: @escaping () -> Bool) {
        self.host = host
        self.shiftedViews = shiftedViews
        self.canPull = canPull
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 18, left: 14, bottom: 28, right: 14)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
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

        tray.backgroundColor = UIColor.systemIndigo.resolvedColor(with: view.traitCollection)
            .withAlphaComponent(0.16)
        tray.layer.cornerRadius = 28
        tray.layer.cornerCurve = .continuous
        tray.layer.borderWidth = 1
        tray.layer.borderColor = UIColor.systemIndigo.withAlphaComponent(0.32).cgColor
        tray.clipsToBounds = false
        view.addSubview(tray)

        tab.text = "a\nr\nc\nh\ni\nv\ne"
        tab.numberOfLines = 7
        tab.textAlignment = .center
        tab.font = .preferredFont(forTextStyle: .caption2)
        tab.adjustsFontForContentSizeCategory = true
        tab.textColor = .white
        tab.backgroundColor = .systemIndigo
        tab.layer.cornerRadius = 10
        tab.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        tab.clipsToBounds = true
        tab.isAccessibilityElement = true
        tab.accessibilityLabel = "Archive"
        tray.addSubview(tab)

        collection.backgroundColor = .clear
        collection.alwaysBounceVertical = true
        collection.dataSource = self
        collection.delegate = self
        collection.register(ArchiveTrayCell.self, forCellWithReuseIdentifier: ArchiveTrayCell.reuseID)
        tray.addSubview(collection)
        let unarchivePress = UILongPressGestureRecognizer(
            target: self, action: #selector(handleUnarchivePress(_:)))
        unarchivePress.cancelsTouchesInView = false
        collection.addGestureRecognizer(unarchivePress)

        emptyLabel.text = "No archived items"
        emptyLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        tray.addSubview(emptyLabel)

        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    func setItems(_ items: [ArchiveTrayItem]) {
        self.items = items
        emptyLabel.isHidden = !items.isEmpty
        collection.reloadData()
    }

    func layout(in bounds: CGRect, safeAreaInsets: UIEdgeInsets) {
        guard bounds.size.width > 0 else { return }
        laidOutSize = bounds.size
        dismissControl.frame = bounds
        let width = bounds.width * 2 / 3
        let top = safeAreaInsets.top + 8
        let bottom = safeAreaInsets.bottom + 8
        tray.bounds = CGRect(x: 0, y: 0, width: width, height: max(0, bounds.height - top - bottom))
        tray.center.y = top + tray.bounds.height / 2
        tab.frame = CGRect(x: -Self.tabWidth, y: 64, width: Self.tabWidth, height: 126)
        collection.frame = tray.bounds
        emptyLabel.frame = tray.bounds.insetBy(dx: 18, dy: 18)
        applyProgress()
        if let layout = collection.collectionViewLayout as? UICollectionViewFlowLayout {
            let usable = width - layout.sectionInset.left - layout.sectionInset.right
                - layout.minimumInteritemSpacing
            let side = floor(usable / 2)
            layout.itemSize = CGSize(width: side, height: side)
        }
    }

    @objc private func dismissTapped() { setOpen(false, animated: true) }

    @objc private func handleUnarchivePress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let indexPath = collection.indexPathForItem(at: gesture.location(in: collection))
        else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        items[indexPath.item].unarchive()
    }

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
        let width = laidOutSize.width * 2 / 3
        let closedX = laidOutSize.width - Self.peek
        let openX = laidOutSize.width - width
        tray.frame.origin.x = closedX + (openX - closedX) * progress
        let shift = -laidOutSize.width * 0.5 * progress
        shiftedViews().forEach { $0.transform = CGAffineTransform(translationX: shift, y: 0) }
        dismissControl.isHidden = progress < 0.01
        dismissControl.alpha = progress * 0.18
        tray.layer.shadowColor = UIColor.black.cgColor
        tray.layer.shadowOpacity = Float(progress * 0.22)
        tray.layer.shadowRadius = 18
        tray.layer.shadowOffset = CGSize(width: -5, height: 0)
    }
}

extension ArchiveTrayController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        let velocity = pan.velocity(in: host?.view)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        return progress > 0 || (velocity.x < 0 && canPull())
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }
}

extension ArchiveTrayController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ArchiveTrayCell.reuseID, for: indexPath) as! ArchiveTrayCell
        cell.configure(with: items[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        items[indexPath.item].tap()
    }

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

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 3
        footerLabel.font = .preferredFont(forTextStyle: .caption2)
        footerLabel.textColor = .secondaryLabel
        unavailableIcon.tintColor = .label
        unavailableIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 25)
        for child in [imageView, titleLabel, footerLabel, unavailableIcon] {
            child.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(child)
        }
        imageCompactConstraint = imageView.heightAnchor.constraint(
            equalTo: contentView.heightAnchor, multiplier: 0.52)
        imageFillConstraint = imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageCompactConstraint,
            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            footerLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            footerLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            footerLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7),
            unavailableIcon.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            unavailableIcon.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        representedID = nil
        imageView.image = nil
        super.prepareForReuse()
    }

    func configure(with item: ArchiveTrayItem) {
        representedID = item.id
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
        item.loadImage { [weak self] image in
            DispatchQueue.main.async {
                guard self?.representedID == item.id else { return }
                self?.imageView.image = image
            }
        }
    }
}
