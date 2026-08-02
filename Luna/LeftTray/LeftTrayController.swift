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

enum LeftTraySetupKind: Equatable {
    case safari
    case shortcut
    case email
}

enum LeftTraySetupVisibility {
    static func showsShortcut(
        saveSetupMode: OnboardingSaveSetupMode,
        setupFlowHandled: Bool,
        shortcutHasRun: Bool
    ) -> Bool {
        saveSetupMode == .actionButtonShortcut
            && !setupFlowHandled
            && !shortcutHasRun
    }
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
        case .paste: return 148
        case .setup(.shortcut): return 54
        case .setup(.email), .setup(.safari): return 88
        case .recent: return 116
        }
    }
}

/// Mirrored archive geometry: its pivot is off the left edge and the cells'
/// right edges approach the apex at the viewport's vertical midpoint.
private final class LeftArcLayout: UICollectionViewLayout {
    var itemWidth: CGFloat = 200
    var itemHeights: [CGFloat] = []
    var spacing: CGFloat = 18
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
        let rotation = min(max(angle, -0.075), 0.075)
        let apexCenterX = collectionView.bounds.width - trailingInset - itemWidth / 2
        attributes.center = CGPoint(
            x: apexCenterX - radius * (1 - cos(angle)),
            y: arcCenters[indexPath.item])
        attributes.transform = CGAffineTransform(rotationAngle: rotation)
        attributes.zIndex = indexPath.item
        return attributes
    }
}

/// The left-of-first-card arc shared by central Luna, Reader, and Downloader.
final class LeftTrayController: NSObject, UIPasteConfigurationSupporting {
    /// Installed only by article-capable app variants, whose target membership
    /// includes the Email settings controller. The shared tray source also
    /// compiles into Downloader/Price Tracker, so it must not name that type.
    static var emailRecoveryLauncher: ((UIViewController) -> Void)?
    /// Per-target composition supplies the correct production root for the
    /// onboarding mock's saved-card stage.
    static var setupJourneyLauncher: ((UIViewController, OnboardingDemoSource) -> Void)?

    private weak var host: UIViewController?
    private let shiftContribution: TrayShiftContribution
    private let canPull: () -> Bool
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
    private var isRemovingSetupRows = false
    private var pullAvailable = false
    private var chromeHidden = false
    private var activeEmailCard: ExpandedEmailSetupCard?
    private var emailAccountSetup: EmailAccountSetup?
    private var keyboardFrameInScreen: CGRect?

    var pasteConfiguration: UIPasteConfiguration?

    private static let peek: CGFloat = 26
    private static let automaticPasteKey = "leftTray.automaticPasteAfterSettings"

    init(
        host: UIViewController,
        shiftedViews: @escaping () -> [UIView],
        canPull: @escaping () -> Bool,
        savedURL: @escaping (String, CaptureSource, UIView) -> Void,
        openStateChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.host = host
        shiftContribution = TrayShiftContribution(shiftedViews: shiftedViews)
        self.canPull = canPull
        self.savedURL = savedURL
        self.openStateChanged = openStateChanged
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [UTType.url.identifier, UTType.plainText.identifier])
        super.init()
        configure()
        // NOT inline: `UIPasteboard.general` is a synchronous XPC round-trip to
        // pasteboardd, and this initializer runs from `viewDidLoad` during scene
        // creation. A slow or wedged pasteboardd (Universal Clipboard churn is
        // enough) then blocks the main thread straight through the 20 s
        // scene-create watchdog and the app is killed with 0x8BADF00D before it
        // ever draws. Nothing here is needed for the first frame — the paste row
        // just appears when the answer lands — so let the scene come up first.
        DispatchQueue.main.async { [weak self] in self?.detectPasteboard() }
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
            self, selector: #selector(readingListChanged),
            name: .readingListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationForegrounded),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(setupStatusChanged),
            name: LunaSetupStatusStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(setupStatusChanged),
            name: AppOnboardingStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentChanged),
            name: EmailAccountStore.accountChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
        LunaSetupStatusStore.startObservingCrossProcessChanges()
        rebuildRows()
    }

    func layout(in bounds: CGRect, safeAreaInsets: UIEdgeInsets) {
        guard bounds.width > 0 else { return }
        let firstLayout = laidOutSize == .zero
        laidOutSize = bounds.size
        if firstLayout { pullAvailable = canPull() }
        dismissControl.frame = bounds
        let width = trayWidth(for: bounds.width)
        let top = safeAreaInsets.top + 8
        let bottom = safeAreaInsets.bottom + 8
        tray.bounds = CGRect(x: 0, y: 0, width: width, height: max(0, bounds.height - top - bottom))
        tray.center.y = top + tray.bounds.height / 2
        collection.frame = tray.bounds
        layout.itemWidth = max(0, floor(width) - 30)
        layout.radius = max(tray.bounds.height, 400) * 1.4
        layout.topInset = max(28, tray.bounds.height / 2 - (rows.first?.height ?? 116) / 2)
        layout.bottomInset = max(28, tray.bounds.height / 2 - (rows.last?.height ?? 116) / 2)
        layout.invalidateLayout()
        updateExpandedEmailFrame(animated: false)
        applyProgress()
    }

    /// 82% of a phone screen, capped on a wide container: past a point the tray
    /// is not a drawer over the deck any more, it is a second screen.
    private func trayWidth(for hostWidth: CGFloat) -> CGFloat {
        min(
            hostWidth - 12,
            max(280, LunaLayout.drawerWidth(forContainerWidth: hostWidth, fraction: 0.82)))
    }

    func refreshPullAvailability(animated: Bool) {
        setPullAvailable(canPull(), animated: animated)
    }

    func setPullAvailable(_ available: Bool, animated: Bool) {
        guard available != pullAvailable else {
            // A carousel reload can replace the first card without a paging
            // callback. Re-assert the closed geometry so the already-available
            // 26pt peek cannot remain stranded offscreen until the user pages.
            if progress < 0.001 { applyTrayPosition() }
            return
        }
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
        if EmailAccountStore.shared.isReady, let card = activeEmailCard {
            dismissExpandedEmailCard(
                card, completed: true, destination: emailRowFrame() ?? card.frame)
            return
        }
        removeCompletedSetupRows()
    }

    @objc private func contentChanged() {
        guard !Thread.isMainThread else {
            rebuildRows()
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.rebuildRows()
        }
    }

    /// The matcher owns the dedupe against the shared reading list, so a store
    /// mutation must republish its cached Safari verdicts rather than merely
    /// rebuilding rows from the matcher's previous snapshot. `refresh()` first
    /// publishes synchronously from cache; only genuinely unseen history URLs
    /// need its asynchronous classification pass.
    @objc private func readingListChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.readingListChanged() }
            return
        }
        RecentURLMatcher.shared.refresh()
    }

    @objc private func setupStatusChanged() {
        // Everything below is UIKit, and this fires from a notification whose
        // posters are background App Intents — mirror `contentChanged`'s hop.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setupStatusChanged() }
            return
        }
        removeCompletedSetupRows()
    }

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
        // `@MainActor` is load-bearing: this class is a plain NSObject, so an
        // unannotated Task resumes on the cooperative pool and `rebuildRows()`
        // below would call `reloadData()` off the main thread — which poisons the
        // collection view's layout engine and aborts at the NEXT main-thread
        // rebuild with "Modifications to the layout engine must not be performed
        // from a background thread".
        pasteEvaluationTask = Task { @MainActor [weak self] in
            let preview = await RecentURLMatcher.evaluate(
                urlString: url.absoluteString, surface: LunaApp.current)
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

    private func makeRows() -> [LeftTrayRow] {
        var next: [LeftTrayRow] = []
        let setup = LunaSetupStatusStore.shared
        if LunaApp.current.sharesByEmail, !EmailAccountStore.shared.isReady {
            next.append(.setup(.email))
        }
        if LeftTraySetupVisibility.showsShortcut(
            saveSetupMode: .current,
            setupFlowHandled: AppOnboardingStore.shared.hasHandledSaveSetup,
            shortcutHasRun: setup.anyShortcutHasRun) {
            next.append(.setup(.shortcut))
        }
        if !setup.safariRunApplies(to: .current) {
            next.append(.setup(.safari))
        }
        next.append(.paste)
        next.append(contentsOf: RecentURLMatcher.shared.matches.map(LeftTrayRow.recent))
        return next
    }

    private func rebuildRows() {
        let next = makeRows()
        rows = next
        layout.itemHeights = rows.map(\.height)
        collection.reloadData()
        layout.invalidateLayout()
        applyProgress()
    }

    /// The indexes of `rows` holding a setup card that `next` no longer has —
    /// the cards that have just earned their way off the arc.
    private func completedSetupIndexes(against next: [LeftTrayRow]) -> [Int] {
        rows.indices.filter { index in
            guard case let .setup(kind) = rows[index] else { return false }
            return !next.contains {
                guard case let .setup(nextKind) = $0 else { return false }
                return nextKind == kind
            }
        }
    }

    /// Setup completion has a little physicality: the finished cards shrink and
    /// fade, then the remaining arc closes up around the paste row.
    ///
    /// Re-entrancy is the whole difficulty here, because the posters are App
    /// Intents and ONE link shared through `SaveIntent` arrives up to three
    /// times inside the 0.24 s fade: `recordShortcutRun`'s in-process
    /// notification, that same call's Darwin echo (this process observes its own
    /// cross-process post), and the save's own `.readingListChanged` rebuild.
    /// Whichever landed second left the deletion below describing a row count
    /// the collection view no longer had, which is a hard UIKit abort rather
    /// than a glitch. So the snapshot taken before the fade is never trusted
    /// after it: the completion re-derives, and anything that is no longer a
    /// plain deletion of setup rows (a save that also ADDED a recent row)
    /// reloads instead of animating.
    private func removeCompletedSetupRows() {
        // The in-flight fade re-derives when it completes, so it already covers
        // whatever this later post is reporting.
        guard !isRemovingSetupRows else { return }
        guard !completedSetupIndexes(against: makeRows()).isEmpty else {
            rebuildRows()
            return
        }
        // Nothing to fade and nobody watching it: an App Intent routinely fires
        // this with the app backgrounded, where a batch update against an
        // off-screen collection view buys only the abort above.
        guard collection.window != nil else {
            rebuildRows()
            return
        }

        let visible = completedSetupIndexes(against: makeRows())
            .compactMap { collection.cellForItem(at: IndexPath(item: $0, section: 0)) }
        isRemovingSetupRows = true
        UIView.animate(
            withDuration: 0.24,
            animations: {
                visible.forEach {
                    $0.alpha = 0
                    $0.transform = CGAffineTransform(scaleX: 0.78, y: 0.78)
                }
            },
            completion: { [weak self] _ in
                guard let self else { return }
                isRemovingSetupRows = false
                let current = makeRows()
                let removed = completedSetupIndexes(against: current)
                guard !removed.isEmpty, current.count == rows.count - removed.count else {
                    rebuildRows()
                    centerPaste(animated: true)
                    return
                }
                rows = current
                layout.itemHeights = current.map(\.height)
                collection.performBatchUpdates({
                    self.collection.deleteItems(
                        at: removed.map { IndexPath(item: $0, section: 0) })
                }, completion: { _ in
                    self.layout.invalidateLayout()
                    self.centerPaste(animated: true)
                })
            })
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
            let travel = max(1, trayWidth(for: laidOutSize.width) - Self.peek)
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
        applyTrayPosition()
        guard laidOutSize.width > 0 else { return }
        updatePasteboardRowPosition()
        let width = trayWidth(for: laidOutSize.width)
        let shift = width * progress
        shiftContribution.apply(shift)
        openStateChanged(progress > 0.001)
        dismissControl.isHidden = progress < 0.01
        dismissControl.alpha = progress * 0.18
    }

    /// The physical clipboard is intentionally narrower and leading-aligned
    /// inside its transparent arc row. Carry it to the row's trailing edge as
    /// the tray closes so the tray's 26-point reveal contains real artwork,
    /// then return it to its normal open position along with the pull.
    private func updatePasteboardRowPosition() {
        guard rows.indices.contains(pasteIndex),
              let cell = collection.cellForItem(
                at: IndexPath(item: pasteIndex, section: 0)) as? LeftTrayCell
        else { return }
        cell.setPasteCollapsedFraction(1 - progress)
    }

    private func applyTrayPosition() {
        guard laidOutSize.width > 0 else { return }
        let width = trayWidth(for: laidOutSize.width)
        let closedX = pullAvailable ? -width + Self.peek : -width
        tray.frame.origin.x = closedX + (0 - closedX) * progress
    }

    private func save(
        _ preview: RecentURLPreview,
        source: CaptureSource,
        sourceView: UIView
    ) {
        savedURL(preview.urlString, source, sourceView)
        setOpen(false, animated: true)
    }

    #if DEBUG
    var trayFrameForTesting: CGRect { tray.frame }

    var pasteboardFrameInTrayForTesting: CGRect? {
        collection.layoutIfNeeded()
        guard rows.indices.contains(pasteIndex),
              let cell = collection.cellForItem(
                at: IndexPath(item: pasteIndex, section: 0)) as? LeftTrayCell
        else { return nil }
        return cell.clipboardFrame(in: tray)
    }

    func offsetTrayForTesting(by deltaX: CGFloat) {
        tray.frame.origin.x += deltaX
    }

    func setOpenForTesting(_ open: Bool) {
        setOpen(open, animated: false)
    }
    #endif

    private func openSettingsForPaste() {
        UserDefaults.standard.set(true, forKey: Self.automaticPasteKey)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        detectPasteboard()
    }

    private func performSetupAction(_ kind: LeftTraySetupKind, from sourceView: UIView) {
        switch kind {
        case .email:
            if EmailAccountStore.shared.authenticationIssue != nil {
                openEmailRecoverySettings()
            } else {
                presentExpandedEmailCard(from: sourceView)
            }
        case .shortcut:
            guard let host else { return }
            Self.setupJourneyLauncher?(host, .messages)
        case .safari:
            guard let host else { return }
            Self.setupJourneyLauncher?(host, .safari)
        }
    }

    private func openEmailRecoverySettings() {
        guard let host else { return }
        setOpen(false, animated: true)
        Self.emailRecoveryLauncher?(host)
    }

    private func presentExpandedEmailCard(from sourceView: UIView) {
        guard activeEmailCard == nil, let host else { return }
        let startFrame = sourceView.convert(sourceView.bounds, to: host.view)
        let card = ExpandedEmailSetupCard()
        card.frame = startFrame
        card.onCancel = { [weak self, weak card] in
            guard let self, let card else { return }
            self.dismissExpandedEmailCard(card, completed: false, destination: startFrame)
        }
        card.onNext = { [weak self, weak card] address in
            guard let self, let card else { return }
            self.beginEmailSetup(address: address, card: card)
        }
        activeEmailCard = card
        host.view.addSubview(card)
        collection.isScrollEnabled = false
        pan.isEnabled = false
        dismissControl.isUserInteractionEnabled = false
        host.view.layoutIfNeeded()
        UIView.animate(
            withDuration: 0.42, delay: 0,
            usingSpringWithDamping: 0.88, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: {
                card.frame = self.expandedEmailFrame()
                card.layer.cornerRadius = 24
                card.layoutIfNeeded()
            },
            completion: { _ in card.focusAddress() })
    }

    private func beginEmailSetup(address: String, card: ExpandedEmailSetupCard) {
        guard emailAccountSetup == nil, let host else { return }
        card.setBusy(true)
        let setup = EmailAccountSetup(
            presenter: host,
            onBusyChange: { [weak card] busy in card?.setBusy(busy) },
            completion: { [weak self, weak card] connected in
                guard let self, let card else { return }
                self.emailAccountSetup = nil
                card.setBusy(false)
                if connected || EmailAccountStore.shared.isReady {
                    let finish = {
                        let destination = self.emailRowFrame() ?? card.frame
                        self.dismissExpandedEmailCard(
                            card, completed: true, destination: destination)
                    }
                    if let nav = host.navigationController,
                       nav.topViewController !== host {
                        nav.popToViewController(host, animated: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: finish)
                    } else {
                        finish()
                    }
                } else {
                    card.focusAddress()
                }
            })
        emailAccountSetup = setup
        if !setup.start(address: address) {
            emailAccountSetup = nil
            card.setBusy(false)
            card.rejectAddress()
        }
    }

    private func dismissExpandedEmailCard(
        _ card: ExpandedEmailSetupCard, completed: Bool, destination: CGRect
    ) {
        card.endEditing(true)
        UIView.animate(
            withDuration: completed ? 0.34 : 0.28,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: {
                card.frame = destination
                card.alpha = 0
                card.transform = completed
                    ? CGAffineTransform(scaleX: 0.72, y: 0.72)
                    : .identity
            },
            completion: { [weak self] _ in
                guard let self else { return }
                card.removeFromSuperview()
                self.activeEmailCard = nil
                self.collection.isScrollEnabled = true
                self.pan.isEnabled = true
                self.dismissControl.isUserInteractionEnabled = true
                if completed {
                    self.removeCompletedSetupRows()
                }
            })
    }

    private func emailRowFrame() -> CGRect? {
        guard let host,
              let index = rows.firstIndex(where: {
                  if case .setup(.email) = $0 { return true }
                  return false
              }),
              let cell = collection.cellForItem(at: IndexPath(item: index, section: 0))
        else { return nil }
        return cell.convert(cell.bounds, to: host.view)
    }

    private func expandedEmailFrame() -> CGRect {
        guard let host else { return .zero }
        let inset: CGFloat = 12
        let bounds = host.view.bounds
        let top = max(inset, host.view.safeAreaInsets.top + inset)
        let keyboardTop: CGFloat
        if let keyboardFrameInScreen {
            keyboardTop = host.view.convert(keyboardFrameInScreen, from: nil).minY
        } else {
            keyboardTop = bounds.height * 0.54
        }
        let bottom = max(top + 280, keyboardTop - inset)
        return CGRect(
            x: inset, y: top, width: bounds.width - inset * 2,
            height: min(bounds.height - top - inset, bottom - top))
    }

    @objc private func keyboardWillChange(_ notification: Notification) {
        keyboardFrameInScreen = notification.userInfo?[
            UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        updateExpandedEmailFrame(animated: true, notification: notification)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardFrameInScreen = nil
        updateExpandedEmailFrame(animated: true, notification: notification)
    }

    private func updateExpandedEmailFrame(
        animated: Bool, notification: Notification? = nil
    ) {
        guard let card = activeEmailCard else { return }
        let changes = { card.frame = self.expandedEmailFrame() }
        guard animated else {
            changes()
            return
        }
        let duration = notification?.userInfo?[
            UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
        let rawCurve = notification?.userInfo?[
            UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        UIView.animate(
            withDuration: duration, delay: 0,
            options: UIView.AnimationOptions(rawValue: rawCurve << 16)
                .union(.beginFromCurrentState),
            animations: changes)
    }

    private func contextMenu(for preview: RecentURLPreview, sourceView: UIView) -> UIMenu {
        UIMenu(children: [
            UIAction(title: L10n.string("Open"), image: UIImage(systemName: "safari")) { _ in
                guard let url = URL(string: preview.urlString) else { return }
                UIApplication.shared.open(url)
            },
            UIAction(title: L10n.string("Share"), image: UIImage(systemName: "square.and.arrow.up")) {
                [weak host] _ in
                guard let host, let url = URL(string: preview.urlString) else { return }
                let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                activity.popoverPresentationController?.sourceView = sourceView
                host.present(activity, animated: true)
            },
        ])
    }
}

/// The email setup row's expanded state. It deliberately stays a view inside
/// the tray's host rather than becoming another onboarding controller, so its
/// geometry can animate directly from and back into the selected card.
private final class ExpandedEmailSetupCard: UIView {
    var onNext: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let addressField = UITextField()
    private let providerBadge = ProviderBadgeView()
    private let providerInfo = UILabel()
    private let nextButton = EmailLoginActionButton(title: L10n.string("Next"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = LunaColors.secondaryBackground
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.20
        layer.shadowRadius = 24
        layer.shadowOffset = CGSize(width: 0, height: 10)
        clipsToBounds = false
        let pulse = CABasicAnimation(keyPath: "shadowOpacity")
        pulse.fromValue = 0.13
        pulse.toValue = 0.27
        pulse.duration = 1.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer.add(pulse, forKey: "setupPulse")

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.accessibilityLabel = L10n.string("Close email setup")
        close.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = L10n.string("Connect your email")
        title.font = .systemFont(ofSize: 27, weight: .bold)
        title.textColor = LunaColors.primaryText
        title.numberOfLines = 1
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.8
        title.translatesAutoresizingMaskIntoConstraints = false

        let body = UILabel()
        body.text = L10n.string("Enter the address Luna should use to send and import links.")
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.textColor = LunaColors.secondaryText
        body.numberOfLines = 2
        body.translatesAutoresizingMaskIntoConstraints = false

        let fieldCard = EmailLoginUI.fieldCard()
        let glyph = EmailLoginUI.leadingGlyph("envelope")
        addressField.placeholder = L10n.string("you@example.com")
        addressField.font = .preferredFont(forTextStyle: .body)
        addressField.textColor = LunaColors.primaryText
        addressField.keyboardType = .emailAddress
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.textContentType = .emailAddress
        addressField.returnKeyType = .next
        addressField.addTarget(self, action: #selector(nextTapped), for: .editingDidEndOnExit)
        addressField.addTarget(self, action: #selector(addressChanged), for: .editingChanged)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        fieldCard.addSubview(glyph)
        fieldCard.addSubview(addressField)
        fieldCard.addSubview(providerBadge)

        providerInfo.font = .preferredFont(forTextStyle: .footnote)
        providerInfo.textColor = LunaColors.secondaryText
        providerInfo.numberOfLines = 1
        providerInfo.translatesAutoresizingMaskIntoConstraints = false

        nextButton.isEnabled = false
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        for view in [close, title, body, fieldCard, providerInfo, nextButton] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            close.widthAnchor.constraint(equalToConstant: 32),
            close.heightAnchor.constraint(equalToConstant: 32),

            title.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),

            fieldCard.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 18),
            fieldCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            fieldCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            glyph.leadingAnchor.constraint(equalTo: fieldCard.leadingAnchor, constant: 15),
            glyph.centerYAnchor.constraint(equalTo: fieldCard.centerYAnchor),
            addressField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            addressField.centerYAnchor.constraint(equalTo: fieldCard.centerYAnchor),
            addressField.trailingAnchor.constraint(equalTo: providerBadge.leadingAnchor, constant: -8),
            providerBadge.trailingAnchor.constraint(equalTo: fieldCard.trailingAnchor, constant: -12),
            providerBadge.centerYAnchor.constraint(equalTo: fieldCard.centerYAnchor),

            providerInfo.topAnchor.constraint(equalTo: fieldCard.bottomAnchor, constant: 8),
            providerInfo.leadingAnchor.constraint(equalTo: fieldCard.leadingAnchor),
            providerInfo.trailingAnchor.constraint(equalTo: fieldCard.trailingAnchor),

            nextButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            nextButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            nextButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
        accessibilityViewIsModal = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func focusAddress() {
        guard !EmailAccountStore.shared.isReady else { return }
        addressField.becomeFirstResponder()
    }

    func setBusy(_ busy: Bool) {
        addressField.isEnabled = !busy
        nextButton.setLoading(busy)
        nextButton.isEnabled = !busy && EmailAccountSetup.isValidAddress(addressField.text ?? "")
    }

    func rejectAddress() {
        addressField.shake()
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        focusAddress()
    }

    @objc private func addressChanged() {
        let address = (addressField.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let providerID = ProviderInference.inferProviderID(for: address)
        let provider = MailProvider.provider(for: providerID)
        providerBadge.setProvider(ProviderBadgeText.text(for: providerID))
        if address.contains("@") {
            if providerID == .generic {
                providerInfo.text = L10n.string("Custom provider · IMAP setup")
            } else if provider.authKind == .oauth {
                providerInfo.text = L10n.string(
                    "\(provider.displayName) · Secure provider sign-in")
            } else {
                providerInfo.text = L10n.string(
                    "\(provider.displayName) · App-specific password")
            }
        } else {
            providerInfo.text = nil
        }
        nextButton.isEnabled = EmailAccountSetup.isValidAddress(address)
    }

    @objc private func nextTapped() {
        let address = addressField.text ?? ""
        guard EmailAccountSetup.isValidAddress(address) else {
            rejectAddress()
            return
        }
        addressField.resignFirstResponder()
        onNext?(address)
    }

    @objc private func cancelTapped() { onCancel?() }
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
            cell.setPasteCollapsedFraction(0)
            cell.configureSetup(
                kind: kind,
                emailIssue: kind == .email
                    ? EmailAccountStore.shared.authenticationIssue : nil,
                tint: LunaSurfacePalette.baseColor)
        case .paste:
            cell.configurePaste(
                state: pasteState, pasteTarget: self,
                settingsAction: { [weak self] in self?.openSettingsForPaste() })
            cell.setPasteCollapsedFraction(1 - progress)
        case .recent(let preview):
            cell.setPasteCollapsedFraction(0)
            cell.configurePreview(preview, showsPasteboardBadge: false)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let source = collectionView.cellForItem(at: indexPath) ?? collectionView
        switch rows[indexPath.item] {
        case .setup(let kind):
            performSetupAction(kind, from: source)
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

    private static let cardBackground = UIColor(
        red: 0.045, green: 0.047, blue: 0.052, alpha: 0.98)
    private static let primaryCardText = UIColor.white
    private static let secondaryCardText = UIColor.white.withAlphaComponent(0.68)

    private let imageView = UIImageView()
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let pasteBadge = UIImageView(image: UIImage(systemName: "doc.on.clipboard"))
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let settingsButton = UIButton(type: .system)
    private let setupVisual = LeftTraySetupVisualView()
    private let clipboardVisual = LeftTrayClipboardView()
    private var pasteControl: UIPasteControl?
    private var titleLeadingConstraint: NSLayoutConstraint!
    private var titleTrailingConstraint: NSLayoutConstraint!
    private var titleTopConstraint: NSLayoutConstraint!
    private var titleCenterYConstraint: NSLayoutConstraint?
    private var clipboardLeadingConstraint: NSLayoutConstraint!
    private var previewKind: RecentURLPreview.Kind?
    private var pasteCollapsedFraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Self.cardBackground
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = false

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 16
        imageView.layer.cornerCurve = .continuous
        symbolView.contentMode = .center
        symbolView.tintColor = Self.primaryCardText
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 28, weight: .medium)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = Self.primaryCardText
        titleLabel.numberOfLines = 2
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = Self.secondaryCardText
        subtitleLabel.numberOfLines = 2
        pasteBadge.tintColor = Self.secondaryCardText

        setupVisual.isHidden = true
        clipboardVisual.isHidden = true
        settingsButton.titleLabel?.numberOfLines = 2
        settingsButton.titleLabel?.textAlignment = .center
        settingsButton.isHidden = true
        pasteBadge.isHidden = true
        spinner.hidesWhenStopped = true

        for view in [
            imageView, symbolView, titleLabel, subtitleLabel, pasteBadge, spinner,
            settingsButton, setupVisual, clipboardVisual,
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
        clipboardLeadingConstraint = clipboardVisual.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: 22)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.40),
            symbolView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            symbolView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            symbolView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.24),
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
            setupVisual.topAnchor.constraint(equalTo: contentView.topAnchor),
            setupVisual.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            setupVisual.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            setupVisual.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            clipboardLeadingConstraint,
            clipboardVisual.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            clipboardVisual.widthAnchor.constraint(equalToConstant: 168),
            clipboardVisual.heightAnchor.constraint(equalToConstant: 142),
            settingsButton.leadingAnchor.constraint(equalTo: clipboardVisual.trailingAnchor, constant: 8),
            settingsButton.centerYAnchor.constraint(equalTo: clipboardVisual.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 34),
            settingsButton.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        // The setup-completion fade leaves its card at alpha 0 and 0.78 scale.
        // If a reload recycles that card instead of deleting it, it must come
        // back as a card and not as an invisible one.
        alpha = 1
        transform = .identity
        previewKind = nil
        pasteCollapsedFraction = 0
        clipboardLeadingConstraint.constant = 22
        pasteControl?.removeFromSuperview()
        pasteControl = nil
        imageView.image = nil
        imageView.isHidden = true
        symbolView.isHidden = true
        titleLabel.text = nil
        subtitleLabel.text = nil
        titleLabel.isHidden = false
        subtitleLabel.isHidden = false
        setupVisual.isHidden = true
        clipboardVisual.isHidden = true
        clipboardVisual.isAccessibilityElement = false
        settingsButton.isHidden = true
        settingsButton.removeTarget(nil, action: nil, for: .allEvents)
        pasteBadge.isHidden = true
        spinner.stopAnimating()
        contentView.layer.removeAllAnimations()
        contentView.layer.sublayers?.first(where: { $0.name == "dashes" })?
            .removeFromSuperlayer()
        contentView.layer.shadowOpacity = 0
        contentView.layer.borderWidth = 0
        contentView.backgroundColor = Self.cardBackground
        replaceTitleLeading(anchor: contentView.leadingAnchor, constant: 14)
        replaceTitleTrailing(anchor: contentView.trailingAnchor, constant: -12)
        replaceTitleTop(anchor: contentView.topAnchor, constant: 14)
        titleCenterYConstraint?.isActive = false
        titleCenterYConstraint = nil
        titleLabel.textAlignment = .natural
        titleLabel.numberOfLines = 2
        isAccessibilityElement = false
        accessibilityTraits = []
        super.prepareForReuse()
    }

    func configurePreview(_ preview: RecentURLPreview, showsPasteboardBadge: Bool) {
        previewKind = preview.kind
        imageView.isHidden = false
        imageView.image = preview.image ?? UIImage(
            systemName: preview.kind == .media ? "play.rectangle.fill"
                : preview.kind == .product ? "bag.fill" : "safari.fill")
        imageView.tintColor = Self.secondaryCardText
        titleLabel.text = preview.title
        subtitleLabel.text = preview.subtitle
        replaceTitleLeading(anchor: imageView.trailingAnchor, constant: 10)
        pasteBadge.isHidden = !showsPasteboardBadge
        accessibilityLabel = [preview.title, preview.subtitle].compactMap { $0 }.joined(separator: ", ")
        accessibilityHint = L10n.string("Saves as a full card")
    }

    func configureSetup(
        kind: LeftTraySetupKind,
        emailIssue: EmailAuthenticationIssue?,
        tint: UIColor
    ) {
        symbolView.isHidden = true
        titleLabel.isHidden = true
        subtitleLabel.isHidden = true
        setupVisual.isHidden = false
        setupVisual.configure(
            kind: kind,
            emailNeedsAttention: emailIssue != nil,
            tint: tint)
        contentView.backgroundColor = .clear
        contentView.layer.borderWidth = 0
        contentView.layer.shadowOpacity = 0
        setupVisual.isAccessibilityElement = false
        isAccessibilityElement = true
        accessibilityLabel = setupVisual.accessibilityLabel
        accessibilityHint = setupVisual.accessibilityHint
        accessibilityTraits = .button
    }

    func configurePaste(
        state: LeftTrayPasteState,
        pasteTarget: UIPasteConfigurationSupporting,
        settingsAction: @escaping () -> Void
    ) {
        imageView.isHidden = true
        symbolView.isHidden = true
        titleLabel.isHidden = true
        subtitleLabel.isHidden = true
        clipboardVisual.isHidden = false
        contentView.backgroundColor = .clear
        contentView.layer.borderWidth = 0
        contentView.layer.shadowOpacity = 0
        switch state {
        case .notPresent:
            clipboardVisual.configure(.empty)
            isAccessibilityElement = true
            accessibilityLabel = clipboardVisual.accessibilityLabel
        case .explicit:
            clipboardVisual.configure(.pasteAvailable)
            clipboardVisual.isAccessibilityElement = false
            isAccessibilityElement = false
            installPasteControl(target: pasteTarget)
            configureSettingsButton(action: settingsAction)
        case .automatic:
            clipboardVisual.configure(.pasteAvailable)
            isAccessibilityElement = true
            accessibilityLabel = L10n.string("Clipboard URL will be checked when the tray opens")
        case .evaluating:
            clipboardVisual.configure(.loading)
            isAccessibilityElement = true
            accessibilityLabel = clipboardVisual.accessibilityLabel
        case .preview(_, let preview):
            clipboardVisual.configure(.preview(preview))
            clipboardVisual.isAccessibilityElement = false
            isAccessibilityElement = true
            accessibilityLabel = clipboardVisual.accessibilityLabel
            accessibilityHint = L10n.string("Saves as a full card")
            accessibilityTraits = .button
        case .failure:
            clipboardVisual.configure(.invalid)
            isAccessibilityElement = true
            accessibilityLabel = clipboardVisual.accessibilityLabel
        }
    }

    func setPasteCollapsedFraction(_ fraction: CGFloat) {
        pasteCollapsedFraction = min(max(fraction, 0), 1)
        updatePasteHorizontalPosition(layOutImmediately: true)
    }

    func clipboardFrame(in view: UIView) -> CGRect {
        clipboardVisual.convert(clipboardVisual.bounds, to: view)
    }

    private func installPasteControl(target: UIPasteConfigurationSupporting) {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .clear
        configuration.baseForegroundColor = .clear
        let control = UIPasteControl(configuration: configuration)
        control.target = target
        // `baseBackgroundColor = .clear` still receives the platform's glass
        // plate on iOS 26+. Keep the real, privacy-authorized control hittable
        // (> 0.01 alpha) while letting the designed paper remain the only UI.
        control.alpha = 0.011
        control.accessibilityLabel = L10n.string("Paste URL")
        control.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(control)
        contentView.insertSubview(control, aboveSubview: clipboardVisual)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: clipboardVisual.leadingAnchor, constant: 8),
            control.trailingAnchor.constraint(equalTo: clipboardVisual.trailingAnchor, constant: -8),
            control.topAnchor.constraint(equalTo: clipboardVisual.topAnchor, constant: 16),
            control.bottomAnchor.constraint(equalTo: clipboardVisual.bottomAnchor, constant: -8),
        ])
        pasteControl = control
    }

    private func configureSettingsButton(action: @escaping () -> Void) {
        settingsButton.isHidden = false
        var config = UIButton.Configuration.tinted()
        config.image = UIImage(systemName: "gearshape.fill")
        config.cornerStyle = .capsule
        config.baseForegroundColor = LunaSurfacePalette.baseColor
        config.baseBackgroundColor = LunaSurfacePalette.baseColor.withAlphaComponent(0.20)
        settingsButton.configuration = config
        settingsButton.accessibilityLabel = L10n.string("Paste setting")
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
        updatePasteHorizontalPosition(layOutImmediately: false)
        if let dashes = contentView.layer.sublayers?.first(where: { $0.name == "dashes" })
            as? CAShapeLayer {
            dashes.frame = contentView.bounds
            dashes.path = UIBezierPath(
                roundedRect: contentView.bounds, cornerRadius: 16).cgPath
        }
    }

    private func updatePasteHorizontalPosition(layOutImmediately: Bool) {
        guard !clipboardVisual.isHidden else {
            clipboardLeadingConstraint.constant = 22
            return
        }
        // Open geometry: 22pt leading + 168pt clipboard. At rest, carry its
        // CENTER to the cell's trailing edge (itself 8pt inside the tray). The
        // tray clips the far half, and its 26pt reveal then shows the polished
        // center clip instead of an indistinct strip of the dark board's edge.
        let openCenterX: CGFloat = 22 + 168 / 2
        let closedOffset = max(0, contentView.bounds.width - openCenterX)
        clipboardLeadingConstraint.constant = 22 + closedOffset * pasteCollapsedFraction
        if layOutImmediately { contentView.layoutIfNeeded() }
    }
}

@MainActor
extension LeftTrayCell: LeftTraySaveTransitionArtworkProviding {
    func makeLeftTraySaveTransitionArtwork(
        in coordinateView: UIView
    ) -> LeftTraySaveTransitionArtwork? {
        guard let previewKind, !imageView.isHidden, !titleLabel.isHidden,
              let title = titleLabel.text
        else { return nil }
        contentView.layoutIfNeeded()

        let thumbnail = UIImageView(image: imageView.image)
        thumbnail.frame = imageView.convert(imageView.bounds, to: coordinateView)
        thumbnail.contentMode = imageView.contentMode
        thumbnail.tintColor = imageView.tintColor
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = imageView.layer.cornerRadius
        thumbnail.layer.cornerCurve = .continuous

        let titleCopy = UILabel()
        titleCopy.text = title
        titleCopy.frame = titleLabel.convert(titleLabel.bounds, to: coordinateView)
        titleCopy.font = titleLabel.font
        titleCopy.textColor = titleLabel.textColor
        titleCopy.numberOfLines = titleLabel.numberOfLines
        titleCopy.lineBreakMode = titleLabel.lineBreakMode
        titleCopy.textAlignment = titleLabel.textAlignment

        let subtitleCopy: UILabel? = subtitleLabel.text.map { text in
            let label = UILabel()
            label.text = text
            label.frame = subtitleLabel.convert(subtitleLabel.bounds, to: coordinateView)
            label.font = subtitleLabel.font
            label.textColor = subtitleLabel.textColor
            label.numberOfLines = subtitleLabel.numberOfLines
            label.lineBreakMode = subtitleLabel.lineBreakMode
            label.textAlignment = subtitleLabel.textAlignment
            return label
        }

        return LeftTraySaveTransitionArtwork(
            kind: previewKind,
            sourceFrame: convert(bounds, to: coordinateView),
            backgroundColor: contentView.backgroundColor ?? .clear,
            cornerRadius: contentView.layer.cornerRadius,
            thumbnail: thumbnail,
            title: titleCopy,
            subtitle: subtitleCopy)
    }
}
