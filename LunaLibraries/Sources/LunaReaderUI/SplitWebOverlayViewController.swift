//
//  SplitWebOverlayViewController.swift
//  LunaReaderUI
//

import LunaDesignSystem
import LunaFetch
import LunaModels
import LunaStorage
import UIKit

/// A full-size reader nested over the reader that opened it.
///
/// Link activation grows a black circle from the link while a second, reader-sized
/// black eclipse rises from below. At top-edge totality the next reader fades in and
/// the reader it covered becomes a tab. Further links repeat the same transition;
/// ancestor tabs accumulate left-to-right and scroll when their favicon-sized minimum
/// widths no longer fit between the leading and trailing controls.
public final class SplitWebOverlayViewController: UIViewController,
    UINavigationControllerDelegate {

    public var onDismiss: (() -> Void)?
    public var onOpen: (() -> Void)?
    public var onClose: (() -> Void)?

    private let url: URL
    private let shareProvider: ReaderShareProviding?
    private let initialSourcePoint: CGPoint
    private let outerURL: URL
    private let outerTitle: String

    private let innerNav = UINavigationController()
    private let header = UIView()
    private let closeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let modeControl = LunaSegmentedControl()
    private let tabScrollView = UIScrollView()
    private let tabContainer = UIView()

    private static let buttonSize: CGFloat = 40
    private static let buttonInset: CGFloat = 16
    private static let tabSpacing: CGFloat = 5
    private static let minimumTabWidth: CGFloat = 38
    private static let expandedChromeHeight: CGFloat = 144
    private static let orderedModes: [ReadingListItem.ReaderMode] = [.scroll, .rsvp, .original]

    private var didAnimateIn = false
    private var didDismiss = false
    private var pendingSourcePoint: CGPoint?
    private var pendingTabInsertion = false
    private var tabButtons: [InlineReaderTabButton] = []

    /// Legacy split arguments remain accepted so existing extension call sites stay
    /// source-compatible. The new presentation intentionally ignores snapshot halves.
    public init(
        url: URL,
        shareProvider: ReaderShareProviding?,
        lineHeight: CGFloat,
        cutY: CGFloat,
        topHalf: UIView?,
        bottomHalf: UIView?,
        sourcePoint: CGPoint? = nil,
        outerURL: URL? = nil,
        outerTitle: String? = nil
    ) {
        self.url = url
        self.shareProvider = shareProvider
        self.initialSourcePoint = sourcePoint ?? CGPoint(x: UIScreen.main.bounds.midX, y: cutY)
        self.outerURL = outerURL ?? url
        self.outerTitle = Self.titleFallback(outerTitle, url: outerURL ?? url)
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setUpInnerNav()
        configureHeader()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        innerNav.view.frame = view.bounds
        layoutHeader()
    }

    public override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard !didAnimateIn else { return }
        didAnimateIn = true
        view.layoutIfNeeded()
        animateOpen()
    }

    private func animateOpen() {
        SharedDiagnosticLog.record(
            "opening inline reader: \(url.absoluteString)", category: "preload-tap")
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onOpen?()

        innerNav.view.alpha = 0
        header.alpha = 0
        header.transform = CGAffineTransform(translationX: 0, y: 20)
        let scene = InlineReaderEclipseScene(
            container: view,
            sourcePoint: CGPoint(
                x: min(max(initialSourcePoint.x, 0), view.bounds.width),
                y: min(max(initialSourcePoint.y, 0), view.bounds.height)))
        scene.animate(atZenith: { [weak self] in
            guard let self else { return }
            self.view.bringSubviewToFront(self.innerNav.view)
            self.view.bringSubviewToFront(self.header)
            self.innerNav.view.alpha = 0
            self.syncHeaderToTopPage(animateNewTab: true)
            UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut]) {
                self.innerNav.view.alpha = 1
            }
            UIView.animate(
                withDuration: 0.28, delay: 0,
                usingSpringWithDamping: 0.76, initialSpringVelocity: 0.9
            ) {
                self.header.alpha = 1
                self.header.transform = .identity
            }
        }, completion: {})
    }

    private func animateDismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onClose?()
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0.16 : 0.26,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            self.view.alpha = 0
            self.view.transform = CGAffineTransform(translationX: 0, y: 22)
        } completion: { _ in
            self.onDismiss?()
            self.dismiss(animated: false)
        }
    }

    // MARK: - Reader stack

    private func setUpInnerNav() {
        let root = makePage(url: url)
        innerNav.setViewControllers([root], animated: false)
        innerNav.setNavigationBarHidden(true, animated: false)
        innerNav.delegate = self
        innerNav.interactivePopGestureRecognizer?.isEnabled = false
        addChild(innerNav)
        view.addSubview(innerNav.view)
        innerNav.didMove(toParent: self)
    }

    private func makePage(url: URL) -> InlineReaderPageViewController {
        let page = InlineReaderPageViewController(
            url: url, headerHeight: Self.expandedChromeHeight)
        page.onLinkActivatedAtPoint = { [weak self, weak page] linkURL, point in
            guard let self, let page else { return }
            let converted = page.view.convert(point, to: self.view)
            self.pushPage(url: linkURL, sourcePoint: converted)
        }
        page.onBecameArticle = { [weak self] in self?.syncHeaderToTopPage() }
        page.onMetadataChanged = { [weak self] in self?.syncHeaderToTopPage() }
        return page
    }

    private func pushPage(url: URL, sourcePoint: CGPoint) {
        guard !didDismiss, pendingSourcePoint == nil else { return }
        pendingSourcePoint = sourcePoint
        pendingTabInsertion = true
        innerNav.pushViewController(makePage(url: url), animated: true)
    }

    private var topPage: InlineReaderPageViewController? {
        innerNav.topViewController as? InlineReaderPageViewController
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard operation == .push, let sourcePoint = pendingSourcePoint else { return nil }
        let animator = InlineReaderEclipseAnimator(
            sourcePoint: sourcePoint, sceneContainer: view
        ) { [weak self] in
            guard let self else { return }
            self.view.bringSubviewToFront(self.innerNav.view)
            self.view.bringSubviewToFront(self.header)
            self.syncHeaderToTopPage(animateNewTab: true)
        }
        pendingSourcePoint = nil
        return animator
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        pendingSourcePoint = nil
        syncHeaderToTopPage()
    }

    private func syncHeaderToTopPage(animateNewTab: Bool = false) {
        closeButton.configuration = GlassStyle.solidCircularButtonConfiguration(
            symbol: innerNav.viewControllers.count == 1 ? "xmark" : "chevron.backward")

        let showsModes = topPage?.isArticle ?? false
        modeControl.isHidden = !showsModes
        if showsModes, let mode = topPage?.readerMode,
           let index = Self.orderedModes.firstIndex(of: mode) {
            modeControl.selectedSegmentIndex = index
        }

        saveButton.configuration = Self.saveButtonConfiguration(title: "Save")
        saveButton.tintColor = GlassStyle.readingAccent
        saveButton.isEnabled = true
        topPage?.setHeaderHeight(activeChromeHeight)
        rebuildTabs(animateNewest: animateNewTab && pendingTabInsertion)
        pendingTabInsertion = false
        layoutHeader()
    }

    // MARK: - Header and tabs

    private func configureHeader() {
        header.backgroundColor = GlassStyle.solidBarColor
        header.layer.shadowColor = UIColor.black.cgColor
        header.layer.shadowOpacity = 0.1
        header.layer.shadowRadius = 12
        header.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.addSubview(header)

        closeButton.configuration = GlassStyle.solidCircularButtonConfiguration(symbol: "xmark")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        header.addSubview(closeButton)

        tabScrollView.showsHorizontalScrollIndicator = false
        tabScrollView.alwaysBounceHorizontal = false
        tabScrollView.clipsToBounds = true
        header.addSubview(tabScrollView)
        tabScrollView.addSubview(tabContainer)

        for (index, mode) in Self.orderedModes.enumerated() {
            modeControl.insertSegment(
                with: ReaderModeIcons.image(for: mode), at: index, animated: false)
        }
        modeControl.selectedSegmentIndex = 0
        modeControl.isHidden = true
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        header.addSubview(modeControl)

        if shareProvider != nil {
            saveButton.configuration = Self.saveButtonConfiguration(title: "Save")
            saveButton.tintColor = GlassStyle.readingAccent
            saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
            header.addSubview(saveButton)
        }
        rebuildTabs(animateNewest: false)
    }

    private func rebuildTabs(animateNewest: Bool) {
        tabButtons.forEach { $0.removeFromSuperview() }
        let ancestors = ancestorDescriptors()
        tabButtons = ancestors.enumerated().map { index, descriptor in
            let button = InlineReaderTabButton(url: descriptor.url, title: descriptor.title)
            button.tag = index
            button.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            tabContainer.addSubview(button)
            return button
        }
        layoutTabs(scrollToRight: true)

        guard animateNewest, let newest = tabButtons.last else { return }
        newest.alpha = 0
        newest.transform = CGAffineTransform(translationX: 0, y: 18).scaledBy(x: 0.86, y: 0.86)
        UIView.animate(
            withDuration: 0.3, delay: 0,
            usingSpringWithDamping: 0.7, initialSpringVelocity: 0.9
        ) {
            newest.alpha = 1
            newest.transform = .identity
        }
    }

    private func ancestorDescriptors() -> [(url: URL, title: String)] {
        var result = [(outerURL, outerTitle)]
        result.append(contentsOf: innerNav.viewControllers.dropLast().compactMap { controller in
            guard let page = controller as? InlineReaderPageViewController else { return nil }
            return (page.url, page.displayTitle)
        })
        return result
    }

    private func layoutHeader() {
        let safeTop = view.safeAreaInsets.top
        header.frame = CGRect(
            x: 0, y: 0, width: view.bounds.width, height: activeChromeHeight)
        let buttonY = safeTop + 4
        closeButton.frame = CGRect(
            x: Self.buttonInset, y: buttonY,
            width: Self.buttonSize, height: Self.buttonSize)

        var trailingWidth = Self.buttonSize
        if saveButton.superview != nil {
            let fit = saveButton.sizeThatFits(
                CGSize(width: view.bounds.width, height: Self.buttonSize))
            trailingWidth = max(fit.width, Self.buttonSize)
            saveButton.frame = CGRect(
                x: view.bounds.width - trailingWidth - Self.buttonInset,
                y: buttonY, width: trailingWidth, height: Self.buttonSize)
        }

        let tabsLeft = closeButton.frame.maxX + 8
        let tabsRight = view.bounds.width - Self.buttonInset - trailingWidth - 8
        tabScrollView.frame = CGRect(
            x: tabsLeft, y: buttonY + 2,
            width: max(tabsRight - tabsLeft, 0), height: Self.buttonSize - 4)
        layoutTabs(scrollToRight: false)

        let modeSize = modeControl.sizeThatFits(CGSize(width: view.bounds.width, height: 34))
        let modeWidth = min(max(modeSize.width, 132), view.bounds.width - 32)
        modeControl.frame = CGRect(
            x: (view.bounds.width - modeWidth) / 2,
            y: closeButton.frame.maxY + 8,
            width: modeWidth, height: 34)
    }

    private var activeChromeHeight: CGFloat {
        modeControl.isHidden
            ? max(view.safeAreaInsets.top + Self.buttonSize + 12, 96)
            : Self.expandedChromeHeight
    }

    private func layoutTabs(scrollToRight: Bool) {
        let count = tabButtons.count
        let totalSpacing = Self.tabSpacing * CGFloat(max(count - 1, 0))
        let metrics = InlineReaderTabMetrics(
            availableWidth: max(tabScrollView.bounds.width - totalSpacing, 0),
            tabCount: count,
            minimumTabWidth: Self.minimumTabWidth)
        var x: CGFloat = 0
        for button in tabButtons {
            button.frame = CGRect(
                x: x, y: 0, width: metrics.tabWidth,
                height: tabScrollView.bounds.height)
            x += metrics.tabWidth + Self.tabSpacing
        }
        let contentWidth = metrics.contentWidth + totalSpacing
        tabContainer.frame = CGRect(
            x: 0, y: 0, width: contentWidth, height: tabScrollView.bounds.height)
        tabScrollView.contentSize = tabContainer.bounds.size
        tabScrollView.alwaysBounceHorizontal = metrics.scrolls
        if scrollToRight {
            tabScrollView.setContentOffset(
                CGPoint(x: max(contentWidth - tabScrollView.bounds.width, 0), y: 0),
                animated: false)
        }
    }

    private static func titleFallback(_ title: String?, url: URL) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return url.host?.replacingOccurrences(of: "www.", with: "") ?? "Reader"
    }

    private static func saveButtonConfiguration(title: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = GlassStyle.readingAccent.withAlphaComponent(0.16)
        config.title = title
        config.cornerStyle = .capsule
        config.baseForegroundColor = GlassStyle.readingAccent
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 8, leading: 14, bottom: 8, trailing: 14)
        return config
    }

    @objc private func closeTapped() {
        if innerNav.viewControllers.count > 1 {
            innerNav.popViewController(animated: true)
        } else {
            animateDismiss()
        }
    }

    @objc private func tabTapped(_ sender: UIButton) {
        if sender.tag == 0 {
            animateDismiss()
            return
        }
        let pageIndex = sender.tag - 1
        guard innerNav.viewControllers.indices.contains(pageIndex) else { return }
        innerNav.popToViewController(innerNav.viewControllers[pageIndex], animated: true)
    }

    @objc private func modeChanged() {
        let index = max(0, min(modeControl.selectedSegmentIndex, Self.orderedModes.count - 1))
        topPage?.setMode(Self.orderedModes[index])
    }

    @objc private func saveTapped() {
        guard let target = topPage?.url else { return }
        shareProvider?.saveLink(urlString: target.absoluteString)
        saveButton.configuration = Self.saveButtonConfiguration(title: "Saved")
        saveButton.tintColor = GlassStyle.readingAccent
        saveButton.isEnabled = false
        layoutHeader()
    }
}

private final class InlineReaderTabButton: UIButton {
    private let faviconView = UIImageView()
    private let titleLabelView = UILabel()
    private var faviconTask: Task<Void, Never>?

    init(url: URL, title: String) {
        super.init(frame: .zero)
        accessibilityLabel = "Return to \(title)"
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.82)
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        clipsToBounds = true

        faviconView.contentMode = .scaleAspectFill
        faviconView.clipsToBounds = true
        faviconView.layer.cornerRadius = 4
        faviconView.image = UIImage(systemName: "globe")
        faviconView.tintColor = .secondaryLabel
        addSubview(faviconView)

        titleLabelView.text = title
        titleLabelView.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabelView.textColor = .label
        titleLabelView.lineBreakMode = .byTruncatingTail
        addSubview(titleLabelView)

        faviconTask = Task { [weak self] in
            guard let data = await FaviconFetcher().fetchIconData(forPageURL: url),
                  !Task.isCancelled,
                  let image = UIImage(data: data) else { return }
            await MainActor.run { self?.faviconView.image = image }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit { faviconTask?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconSide: CGFloat = 18
        let leading: CGFloat = 8
        faviconView.frame = CGRect(
            x: leading, y: (bounds.height - iconSide) / 2,
            width: iconSide, height: iconSide)
        let titleX = faviconView.frame.maxX + 6
        titleLabelView.frame = CGRect(
            x: titleX, y: 0,
            width: max(bounds.width - titleX - 7, 0), height: bounds.height)
        titleLabelView.isHidden = bounds.width < 60
    }
}
