//
//  LeftTrayController.swift
//  Luna
//

import LunaDesignSystem
import LunaMailAccount
import LunaModels
import LunaReadingList
import LunaReadingListUI
import LunaStorage
import LunaURLClassification
import UIKit
import UniformTypeIdentifiers

enum LeftTraySetupKind {
    case safari
    case shortcut
    case email
}

private enum LeftTrayPasteState {
    case notPresent(changeCount: Int)
    case explicit(changeCount: Int)
    case automatic(changeCount: Int)
    case evaluating(changeCount: Int)
    case preview(changeCount: Int, RecentURLPreview)
    case failure(changeCount: Int)

    var changeCount: Int {
        switch self {
        case let .notPresent(value), let .explicit(value), let .automatic(value),
             let .evaluating(value), let .preview(value, _), let .failure(value):
            return value
        }
    }
}

private enum LeftTrayRow {
    case setup(LeftTraySetupKind)
    case paste
    case recent(RecentURLPreview)

    var height: CGFloat {
        switch self {
        case .paste: return 154
        case .setup, .recent: return 116
        }
    }
}

/// Mirrored archive geometry: its pivot is off the left edge and the cells'
/// right edges approach the apex at the viewport's vertical midpoint.
private final class LeftArcLayout: UICollectionViewLayout {
    var itemWidth: CGFloat = 200
    var itemHeights: [CGFloat] = []
    var spacing: CGFloat = 10
    var topInset: CGFloat = 28
    var bottomInset: CGFloat = 28
    var trailingInset: CGFloat = 8
    var radius: CGFloat = 1_000

    private var arcCenters: [CGFloat] = []
    private var contentHeight: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        arcCenters.removeAll()
        var y = topInset
        for index in 0..<collectionView.numberOfItems(inSection: 0) {
            let height = itemHeights.indices.contains(index) ? itemHeights[index] : 116
            arcCenters.append(y + height / 2)
            y += height + spacing
        }
        contentHeight = arcCenters.isEmpty ? 0 : y - spacing + bottomInset
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

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
        let height = itemHeights.indices.contains(indexPath.item)
            ? itemHeights[indexPath.item] : 116
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.size = CGSize(width: itemWidth, height: height)
        let viewportMid = collectionView.contentOffset.y + collectionView.bounds.height / 2
        let angle = (arcCenters[indexPath.item] - viewportMid) / max(radius, 1)
        let apexCenterX = collectionView.bounds.width - trailingInset - itemWidth / 2
        attributes.center = CGPoint(
            x: apexCenterX - radius * (1 - cos(angle)),
            y: viewportMid + radius * sin(angle))
        attributes.transform = CGAffineTransform(rotationAngle: angle)
        attributes.zIndex = indexPath.item
        return attributes
    }
}

/// The left-of-first-card arc shared by central Luna, Reader, and Downloader.
final class LeftTrayController: NSObject, UIPasteConfigurationSupporting {
    private weak var host: UIViewController?
    private let shiftedViews: () -> [UIView]
    private let canPull: () -> Bool
    private let setupTapped: (LeftTraySetupKind) -> Void
    private let savedURL: (String, CaptureSource, UIView) -> Void
    private let openStateChanged: (Bool) -> Void

    private let tray = UIView()
    private let dismissControl = UIControl()
    private let layout = LeftArcLayout()
    private let collection: UICollectionView
    private var pan: UIPanGestureRecognizer!
    private var rows: [LeftTrayRow] = []
    private var pasteState: LeftTrayPasteState = .notPresent(changeCount: -1)
    private var pasteEvaluationTask: Task<Void, Never>?
    private var progress: CGFloat = 0
    private var panStartProgress: CGFloat = 0
    private var laidOutSize = CGSize.zero
    private var pullAvailable = false
    private var chromeHidden = false

    var pasteConfiguration: UIPasteConfiguration?

    private static let peek: CGFloat = 26
    private static let automaticPasteKey = "leftTray.automaticPasteAfterSettings"

    init(
        host: UIViewController,
        shiftedViews: @escaping () -> [UIView],
        canPull: @escaping () -> Bool,
        setupTapped: @escaping (LeftTraySetupKind) -> Void,
        savedURL: @escaping (String, CaptureSource, UIView) -> Void,
        openStateChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.host = host
        self.shiftedViews = shiftedViews
        self.canPull = canPull
        self.setupTapped = setupTapped
        self.savedURL = savedURL
        self.openStateChanged = openStateChanged
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [UTType.url.identifier, UTType.plainText.identifier])
        super.init()
        configure()
        detectPasteboard()
        RecentURLMatcher.shared.refresh()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private var usesAutomaticPaste: Bool {
        UserDefaults.standard.bool(forKey: Self.automaticPasteKey)
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
        collection.register(
            LeftTrayCell.self, forCellWithReuseIdentifier: LeftTrayCell.reuseID)
        tray.addSubview(collection)

        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        NotificationCenter.default.addObserver(
            self, selector: #selector(pasteboardChanged),
            name: UIPasteboard.changedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentChanged),
            name: RecentURLMatcher.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentChanged),
            name: .readingListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationForegrounded),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        rebuildRows()
    }

    func layout(in bounds: CGRect, safeAreaInsets: UIEdgeInsets) {
        guard bounds.width > 0 else { return }
        let firstLayout = laidOutSize == .zero
        laidOutSize = bounds.size
        if firstLayout { pullAvailable = canPull() }
        dismissControl.frame = bounds
        let width = bounds.width * 2 / 3
        let top = safeAreaInsets.top + 8
        let bottom = safeAreaInsets.bottom + 8
        tray.bounds = CGRect(x: 0, y: 0, width: width, height: max(0, bounds.height - top - bottom))
        tray.center.y = top + tray.bounds.height / 2
        collection.frame = tray.bounds
        layout.itemWidth = max(0, floor(width) - 56)
        layout.radius = max(tray.bounds.height, 400) * 1.4
        layout.topInset = max(28, tray.bounds.height / 2 - (rows.first?.height ?? 116) / 2)
        layout.bottomInset = max(28, tray.bounds.height / 2 - (rows.last?.height ?? 116) / 2)
        layout.invalidateLayout()
        applyProgress()
    }

    func refreshPullAvailability(animated: Bool) {
        setPullAvailable(canPull(), animated: animated)
    }

    func setPullAvailable(_ available: Bool, animated: Bool) {
        guard available != pullAvailable else { return }
        pullAvailable = available
        if !available { progress = 0 }
        animateChanges(animated: animated, duration: 0.32) { self.applyProgress() }
    }

    func setChromeHidden(_ hidden: Bool, animated: Bool) {
        guard hidden != chromeHidden else { return }
        chromeHidden = hidden
        if hidden, progress > 0.001 { setOpen(false, animated: animated) }
        animateChanges(animated: animated, duration: 0.32) {
            self.tray.alpha = hidden ? 0 : 1
        }
    }

    func dismiss(animated: Bool) { setOpen(false, animated: animated) }

    @objc private func applicationForegrounded() {
        detectPasteboard()
        RecentURLMatcher.shared.refresh()
        rebuildRows()
    }

    @objc private func contentChanged() { rebuildRows() }

    @objc private func pasteboardChanged() {
        pasteEvaluationTask?.cancel()
        detectPasteboard()
    }

    private func detectPasteboard() {
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        let probableURL = \UIPasteboard.DetectedValues.probableWebURL
        pasteboard.detectPatterns(
            for: [probableURL]
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, UIPasteboard.general.changeCount == changeCount else { return }
                let hasURL = (try? result.get().contains(probableURL)) == true
                if !hasURL {
                    self.pasteState = .notPresent(changeCount: changeCount)
                } else {
                    self.pasteState = self.usesAutomaticPaste
                        ? .automatic(changeCount: changeCount)
                        : .explicit(changeCount: changeCount)
                }
                self.rebuildRows()
            }
        }
    }

    /// `UIPasteControl`'s authorized delivery path.
    func paste(itemProviders: [NSItemProvider]) {
        if let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                DispatchQueue.main.async {
                    self?.evaluatePastedString(url?.absoluteString)
                }
            }
            return
        }
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) })
        else {
            showPasteFailure()
            return
        }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
            DispatchQueue.main.async {
                self?.evaluatePastedString((value as? NSString) as String?)
            }
        }
    }

    private func readPasteboardAutomatically() {
        evaluatePastedString(UIPasteboard.general.url?.absoluteString
            ?? UIPasteboard.general.string)
    }

    private func evaluatePastedString(_ value: String?) {
        let changeCount = UIPasteboard.general.changeCount
        guard let value, let url = URLUnwrapper.ingestURL(from: value) else {
            pasteState = .failure(changeCount: changeCount)
            rebuildRows()
            return
        }
        pasteState = .evaluating(changeCount: changeCount)
        rebuildRows()
        pasteEvaluationTask?.cancel()
        pasteEvaluationTask = Task { [weak self] in
            let preview = await RecentURLMatcher.evaluate(
                urlString: url.absoluteString, surface: AppSurfaceConfig.current)
            guard let self, !Task.isCancelled,
                  UIPasteboard.general.changeCount == changeCount else { return }
            pasteState = preview.map { .preview(changeCount: changeCount, $0) }
                ?? .failure(changeCount: changeCount)
            rebuildRows()
        }
    }

    private func showPasteFailure() {
        pasteState = .failure(changeCount: UIPasteboard.general.changeCount)
        rebuildRows()
    }

    private func rebuildRows() {
        var next: [LeftTrayRow] = []
        let setup = LunaSetupStatusStore.shared
        let isCentral = AppSurfaceConfig.current == .all
        if AppSurfaceConfig.current.sharesByEmail, !EmailAccountStore.shared.isConfigured {
            next.append(.setup(.email))
        }
        if !setup.shortcutHasRun(isCentral: isCentral) {
            next.append(.setup(.shortcut))
        }
        if !setup.safariHasRun(isCentral: isCentral) {
            next.append(.setup(.safari))
        }
        next.append(.paste)
        next.append(contentsOf: RecentURLMatcher.shared.matches.map(LeftTrayRow.recent))
        rows = next
        layout.itemHeights = rows.map(\.height)
        collection.reloadData()
        layout.invalidateLayout()
        applyProgress()
    }

    private var pasteIndex: Int {
        rows.firstIndex {
            if case .paste = $0 { return true }
            return false
        } ?? 0
    }

    private func centerPaste(animated: Bool) {
        guard rows.indices.contains(pasteIndex) else { return }
        collection.layoutIfNeeded()
        collection.scrollToItem(
            at: IndexPath(item: pasteIndex, section: 0),
            at: .centeredVertically, animated: animated)
    }

    @objc private func dismissTapped() { setOpen(false, animated: true) }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard laidOutSize.width > 0 else { return }
        switch gesture.state {
        case .began:
            panStartProgress = progress
            if progress < 0.01 { centerPaste(animated: false) }
        case .changed:
            let travel = max(1, laidOutSize.width * 2 / 3 - Self.peek)
            progress = min(max(
                panStartProgress + gesture.translation(in: host?.view).x / travel, 0), 1)
            applyProgress()
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: host?.view).x
            setOpen(velocity > 220 || (velocity >= -220 && progress >= 0.42), animated: true)
        default:
            break
        }
    }

    private func setOpen(_ open: Bool, animated: Bool) {
        if open {
            centerPaste(animated: false)
            if case .automatic = pasteState { readPasteboardAutomatically() }
        } else {
            centerPaste(animated: animated)
        }
        progress = open ? 1 : 0
        animateChanges(animated: animated, duration: 0.36) { self.applyProgress() }
    }

    private func animateChanges(
        animated: Bool, duration: TimeInterval, changes: @escaping () -> Void
    ) {
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: duration, delay: 0,
                usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState],
                animations: changes)
        } else {
            changes()
        }
    }

    private func applyProgress() {
        guard laidOutSize.width > 0 else { return }
        let width = laidOutSize.width * 2 / 3
        let closedX = pullAvailable ? -width + Self.peek : -width
        tray.frame.origin.x = closedX + (0 - closedX) * progress
        let shift = laidOutSize.width * 2 / 3 * progress
        shiftedViews().forEach { $0.transform = CGAffineTransform(translationX: shift, y: 0) }
        openStateChanged(progress > 0.001)
        dismissControl.isHidden = progress < 0.01
        dismissControl.alpha = progress * 0.18
    }

    private func save(
        _ preview: RecentURLPreview,
        source: CaptureSource,
        sourceView: UIView
    ) {
        savedURL(preview.urlString, source, sourceView)
        setOpen(false, animated: true)
    }

    private func openSettingsForPaste() {
        UserDefaults.standard.set(true, forKey: Self.automaticPasteKey)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        detectPasteboard()
    }

    private func contextMenu(for preview: RecentURLPreview, sourceView: UIView) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Open", image: UIImage(systemName: "safari")) { _ in
                guard let url = URL(string: preview.urlString) else { return }
                UIApplication.shared.open(url)
            },
            UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) {
                [weak host] _ in
                guard let host, let url = URL(string: preview.urlString) else { return }
                let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                activity.popoverPresentationController?.sourceView = sourceView
                host.present(activity, animated: true)
            },
        ])
    }
}

extension LeftTrayController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        guard !chromeHidden else { return false }
        let velocity = pan.velocity(in: host?.view)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        return progress > 0 || (velocity.x > 0 && canPull())
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }
}

extension LeftTrayController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView, numberOfItemsInSection section: Int
    ) -> Int { rows.count }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: LeftTrayCell.reuseID, for: indexPath) as! LeftTrayCell
        switch rows[indexPath.item] {
        case .setup(let kind):
            cell.configureSetup(kind: kind, tint: LunaSurfacePalette.baseColor)
        case .paste:
            cell.configurePaste(
                state: pasteState, pasteTarget: self,
                settingsAction: { [weak self] in self?.openSettingsForPaste() })
        case .recent(let preview):
            cell.configurePreview(preview, showsPasteboardBadge: false)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let source = collectionView.cellForItem(at: indexPath) ?? collectionView
        switch rows[indexPath.item] {
        case .setup(let kind):
            setupTapped(kind)
        case .paste:
            if case let .preview(_, preview) = pasteState {
                save(preview, source: .paste, sourceView: source)
            }
        case .recent(let preview):
            save(preview, source: .manual, sourceView: source)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        let preview: RecentURLPreview?
        switch rows[indexPath.item] {
        case .recent(let value): preview = value
        case .paste:
            if case let .preview(_, value) = pasteState { preview = value } else { preview = nil }
        case .setup: preview = nil
        }
        guard let preview else { return nil }
        let source = collectionView.cellForItem(at: indexPath) ?? collectionView
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            self?.contextMenu(for: preview, sourceView: source)
        })
    }
}

private final class LeftTrayCell: UICollectionViewCell {
    static let reuseID = "LeftTrayCell"

    private let imageView = UIImageView()
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let pasteBadge = UIImageView(image: UIImage(systemName: "doc.on.clipboard"))
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let settingsButton = UIButton(type: .system)
    private var pasteControl: UIPasteControl?
    private var titleLeadingConstraint: NSLayoutConstraint!
    private var titleTrailingConstraint: NSLayoutConstraint!
    private var titleTopConstraint: NSLayoutConstraint!
    private var titleCenterYConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = LunaColors.tertiaryBackground
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = false

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 16
        imageView.layer.cornerCurve = .continuous
        symbolView.contentMode = .center
        symbolView.tintColor = LunaColors.primaryText
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 28, weight: .medium)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.numberOfLines = 2
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = LunaColors.secondaryText
        subtitleLabel.numberOfLines = 2
        pasteBadge.tintColor = LunaColors.secondaryText
        settingsButton.titleLabel?.numberOfLines = 2
        settingsButton.titleLabel?.textAlignment = .center
        settingsButton.isHidden = true
        pasteBadge.isHidden = true
        spinner.hidesWhenStopped = true

        for view in [
            imageView, symbolView, titleLabel, subtitleLabel, pasteBadge, spinner, settingsButton,
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        titleLeadingConstraint = titleLabel.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: 14)
        titleTrailingConstraint = titleLabel.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor, constant: -12)
        titleTopConstraint = titleLabel.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: 14)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.40),
            symbolView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            symbolView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            symbolView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.30),
            titleTopConstraint,
            titleLeadingConstraint,
            titleTrailingConstraint,
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(greaterThanOrEqualTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            pasteBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            pasteBadge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -9),
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            settingsButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            settingsButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            settingsButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        pasteControl?.removeFromSuperview()
        pasteControl = nil
        imageView.image = nil
        imageView.isHidden = true
        symbolView.isHidden = true
        titleLabel.text = nil
        subtitleLabel.text = nil
        settingsButton.isHidden = true
        settingsButton.removeTarget(nil, action: nil, for: .allEvents)
        pasteBadge.isHidden = true
        spinner.stopAnimating()
        contentView.layer.removeAllAnimations()
        contentView.layer.sublayers?.first(where: { $0.name == "dashes" })?
            .removeFromSuperlayer()
        contentView.layer.shadowOpacity = 0
        contentView.layer.borderWidth = 0
        contentView.backgroundColor = LunaColors.tertiaryBackground
        replaceTitleLeading(anchor: contentView.leadingAnchor, constant: 14)
        replaceTitleTrailing(anchor: contentView.trailingAnchor, constant: -12)
        replaceTitleTop(anchor: contentView.topAnchor, constant: 14)
        titleCenterYConstraint?.isActive = false
        titleCenterYConstraint = nil
        titleLabel.textAlignment = .natural
        super.prepareForReuse()
    }

    func configurePreview(_ preview: RecentURLPreview, showsPasteboardBadge: Bool) {
        imageView.isHidden = false
        imageView.image = preview.image ?? UIImage(
            systemName: preview.kind == .media ? "play.rectangle.fill"
                : preview.kind == .product ? "bag.fill" : "safari.fill")
        imageView.tintColor = LunaColors.secondaryText
        titleLabel.text = preview.title
        subtitleLabel.text = preview.subtitle
        replaceTitleLeading(anchor: imageView.trailingAnchor, constant: 10)
        pasteBadge.isHidden = !showsPasteboardBadge
        accessibilityLabel = [preview.title, preview.subtitle].compactMap { $0 }.joined(separator: ", ")
        accessibilityHint = "Saves as a full card"
    }

    func configureSetup(kind: LeftTraySetupKind, tint: UIColor) {
        symbolView.isHidden = false
        let symbol: String
        switch kind {
        case .safari:
            symbol = "safari"
            titleLabel.text = "Set up Safari"
            subtitleLabel.text = "Save as you browse"
        case .shortcut:
            symbol = "square.and.arrow.down.on.square"
            titleLabel.text = "Install Shortcut"
            subtitleLabel.text = "Save from the Action Button"
        case .email:
            symbol = "envelope.badge"
            titleLabel.text = "Connect Email"
            subtitleLabel.text = "Send articles and import links"
        }
        symbolView.image = UIImage(systemName: symbol)
        symbolView.tintColor = tint
        replaceTitleLeading(anchor: symbolView.trailingAnchor, constant: 6)
        contentView.layer.borderWidth = 1
        contentView.layer.borderColor = tint.withAlphaComponent(0.55).cgColor
        contentView.layer.shadowColor = tint.cgColor
        contentView.layer.shadowOffset = .zero
        contentView.layer.shadowRadius = 9
        contentView.layer.shadowOpacity = 0.18
        let pulse = CABasicAnimation(keyPath: "shadowOpacity")
        pulse.fromValue = 0.10
        pulse.toValue = 0.30
        pulse.duration = 1.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        contentView.layer.add(pulse, forKey: "setupPulse")
        accessibilityLabel = titleLabel.text
        accessibilityHint = subtitleLabel.text
    }

    func configurePaste(
        state: LeftTrayPasteState,
        pasteTarget: UIPasteConfigurationSupporting,
        settingsAction: @escaping () -> Void
    ) {
        switch state {
        case .notPresent:
            titleLabel.text = "No URL to paste"
            titleLabel.textAlignment = .center
            titleTopConstraint.isActive = false
            titleCenterYConstraint = titleLabel.centerYAnchor.constraint(
                equalTo: contentView.centerYAnchor)
            titleCenterYConstraint?.isActive = true
            contentView.backgroundColor = .clear
            contentView.layer.sublayers?.first(where: { $0.name == "dashes" })?.removeFromSuperlayer()
            let dashes = CAShapeLayer()
            dashes.name = "dashes"
            dashes.strokeColor = LunaColors.secondaryText.cgColor
            dashes.fillColor = UIColor.clear.cgColor
            dashes.lineDashPattern = [5, 5]
            dashes.path = UIBezierPath(
                roundedRect: contentView.bounds, cornerRadius: 16).cgPath
            dashes.frame = contentView.bounds
            contentView.layer.addSublayer(dashes)
        case .explicit:
            titleLabel.text = "Paste URL"
            titleLabel.textAlignment = .center
            installPasteControl(target: pasteTarget)
            configureSettingsButton(action: settingsAction)
        case .automatic:
            symbolView.isHidden = false
            symbolView.image = UIImage(systemName: "doc.on.clipboard")
            titleLabel.text = "Paste URL automatically"
            subtitleLabel.text = "Opens when this tray is opened"
        case .evaluating:
            titleLabel.text = "Checking URL"
            titleLabel.textAlignment = .center
            spinner.startAnimating()
        case .preview(_, let preview):
            configurePreview(preview, showsPasteboardBadge: true)
        case .failure:
            symbolView.isHidden = false
            symbolView.image = UIImage(systemName: "doc.on.clipboard")
            titleLabel.text = "Invalid URL"
            replaceTitleLeading(anchor: symbolView.trailingAnchor, constant: 6)
        }
    }

    private func installPasteControl(target: UIPasteConfigurationSupporting) {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = GlassStyle.lunaBrandAccent
        configuration.baseForegroundColor = .clear
        let control = UIPasteControl(configuration: configuration)
        control.target = target
        control.accessibilityLabel = "Paste URL"
        control.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(control)
        contentView.insertSubview(control, aboveSubview: titleLabel)
        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            control.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            control.widthAnchor.constraint(equalToConstant: 150),
            control.heightAnchor.constraint(equalToConstant: 44),
        ])
        replaceTitleTop(anchor: control.topAnchor, constant: 10)
        replaceTitleLeading(anchor: control.leadingAnchor, constant: 12)
        replaceTitleTrailing(anchor: control.trailingAnchor, constant: -12)
        titleLabel.isUserInteractionEnabled = false
        pasteControl = control
    }

    private func configureSettingsButton(action: @escaping () -> Void) {
        settingsButton.isHidden = false
        var text = AttributedString("Or change Paste setting to “Allow”")
        if let range = text.range(of: "Paste setting") {
            text[range].foregroundColor = LunaSurfacePalette.baseColor
            text[range].underlineStyle = .single
        }
        var config = UIButton.Configuration.plain()
        config.attributedTitle = text
        config.baseForegroundColor = LunaColors.secondaryText
        settingsButton.configuration = config
        let identifier = UIAction.Identifier("leftTrayPasteSettings")
        settingsButton.removeAction(identifiedBy: identifier, for: .touchUpInside)
        settingsButton.addAction(
            UIAction(identifier: identifier) { _ in action() },
            for: .touchUpInside)
    }

    private func replaceTitleLeading(anchor: NSLayoutXAxisAnchor, constant: CGFloat) {
        titleLeadingConstraint?.isActive = false
        titleLeadingConstraint = titleLabel.leadingAnchor.constraint(
            equalTo: anchor, constant: constant)
        titleLeadingConstraint.isActive = true
    }

    private func replaceTitleTop(anchor: NSLayoutYAxisAnchor, constant: CGFloat) {
        titleTopConstraint?.isActive = false
        titleTopConstraint = titleLabel.topAnchor.constraint(
            equalTo: anchor, constant: constant)
        titleTopConstraint.isActive = true
    }

    private func replaceTitleTrailing(anchor: NSLayoutXAxisAnchor, constant: CGFloat) {
        titleTrailingConstraint?.isActive = false
        titleTrailingConstraint = titleLabel.trailingAnchor.constraint(
            equalTo: anchor, constant: constant)
        titleTrailingConstraint.isActive = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let dashes = contentView.layer.sublayers?.first(where: { $0.name == "dashes" })
            as? CAShapeLayer {
            dashes.frame = contentView.bounds
            dashes.path = UIBezierPath(
                roundedRect: contentView.bounds, cornerRadius: 16).cgPath
        }
    }
}
