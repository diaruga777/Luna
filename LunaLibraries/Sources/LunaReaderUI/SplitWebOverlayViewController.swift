//
//  SplitWebOverlayViewController.swift
//  LunaReaderUI
//

import LunaDesignSystem
import LunaFetch
import LunaModels
import LunaStorage
import UIKit

/// Optional bridge implemented by containers such as the root card carousel.
/// It lets an embedded reader dismiss its surrounding card chrome in lockstep
/// with the eclipse without coupling LunaReaderUI to the app target.
public protocol InlineReaderPresentationCoordinating: AnyObject {
    /// The stable host chrome should begin controlling `reader`.
    func inlineReaderWillPresent(_ reader: ReaderChromeControlling)
    /// Restore the outer reader as the stable chrome's target.
    func inlineReaderDidDismiss(_ reader: ReaderChromeControlling)
    /// Top edge of the existing reader card in window coordinates.
    var inlineReaderTopEdgeInWindow: CGFloat { get }
    /// Resting reader-card frame in window coordinates.
    var inlineReaderCardFrameInWindow: CGRect { get }
    /// Whether the outer reader is scrollable content that remains visible below.
    var inlineReaderShowsOuterContentBelow: Bool { get }
}

/// A reader nested inside the outer reader's fixed chrome.
///
/// Link activation grows a black circle from the link while a second, reader-sized
/// black eclipse rises from below. At top-edge totality the next reader fades in and
/// the reader it covered becomes a tab. Further links repeat the same transition;
/// ancestor tabs accumulate left-to-right and scroll when their favicon-sized minimum
/// widths no longer fit.
public final class SplitWebOverlayViewController: UIViewController,
    UINavigationControllerDelegate, UIViewControllerTransitioningDelegate,
    ReaderChromeControlling {

    public var onDismiss: (() -> Void)?
    public var onOpen: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onChromeStateChanged: (() -> Void)?

    private let url: URL
    private let initialSourcePoint: CGPoint
    private let outerURL: URL
    private let outerTitle: String
    private let cardFrameInWindow: CGRect
    private let shareProvider: ReaderShareProviding?
    private let showsOuterContentBelow: Bool

    private let innerNav = UINavigationController()
    private let cardView = CarouselCardView()
    private let tabBar = UIView()
    private let tabScrollView = UIScrollView()
    private let tabContainer = UIView()

    private static let tabBarHeight: CGFloat = 42
    private static let tabBottomOverlap: CGFloat = 4
    private static let tabSpacing: CGFloat = -9
    private static let minimumTabWidth: CGFloat = 38
    private static let orderedModes: [ReadingListItem.ReaderMode] = [.scroll, .rsvp, .original]

    private var didDismiss = false
    private var pendingSourcePoint: CGPoint?
    private var pendingTabInsertion = false
    private var pageSourcePoints: [ObjectIdentifier: CGPoint] = [:]
    private var tabButtons: [InlineReaderTabButton] = []
    private var isAnimatingTabLayout = false
    private var isNavigatingInlineStack = false
    private var pendingTabRemovalAnimation = false

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
        outerTitle: String? = nil,
        contentTop: CGFloat = 0,
        cardFrame: CGRect? = nil,
        showsOuterContentBelow: Bool = false
    ) {
        self.url = url
        self.initialSourcePoint = sourcePoint ?? CGPoint(x: UIScreen.main.bounds.midX, y: cutY)
        self.outerURL = outerURL ?? url
        self.outerTitle = Self.titleFallback(outerTitle, url: outerURL ?? url)
        self.shareProvider = shareProvider
        self.showsOuterContentBelow = showsOuterContentBelow
        self.cardFrameInWindow = cardFrame ?? CGRect(
            x: 0, y: max(contentTop, 0), width: UIScreen.main.bounds.width,
            height: max(UIScreen.main.bounds.height - max(contentTop, 0), 0))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        transitioningDelegate = self
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureTabBar()
        cardView.setBorderEnabled(true)
        cardView.setContentEdgeFadeHeight(28)
        view.addSubview(cardView)
        setUpInnerNav()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        cardView.frame = localCardFrame
        innerNav.view.frame = cardView.contentContainer.bounds
        layoutTabBar()
    }

    private func transitionWillOpen() {
        SharedDiagnosticLog.record(
            "opening inline reader: \(url.absoluteString)", category: "preload-tap")
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onOpen?()
    }

    private func animateDismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        dismiss(animated: true)
    }

    // MARK: - Modal eclipse presentation

    public func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        InlineReaderPresentationController(
            presentedViewController: presented, presenting: presenting,
            cardFrameInWindow: cardFrameInWindow,
            presentationFrameInWindow: presentationFrameInWindow,
            showsOuterContentBelow: showsOuterContentBelow)
    }

    public func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        InlineReaderEclipseAnimator(
            sourcePoint: initialSourcePoint,
            direction: .forward,
            sceneFrame: cardFrameInWindow,
            onTransitionStart: { [weak self] in self?.transitionWillOpen() },
            atZenith: { [weak self] in
                guard let self else { return }
                self.pendingTabInsertion = true
                self.syncHeaderToTopPage(animateNewTab: true)
            })
    }

    public func animationController(forDismissed dismissed: UIViewController)
        -> UIViewControllerAnimatedTransitioning? {
        let animator = InlineReaderEclipseAnimator(
            sourcePoint: initialSourcePoint,
            direction: .reverse,
            sceneFrame: cardFrameInWindow,
            onTransitionStart: { [weak self] in self?.onClose?() },
            atZenith: { [weak self] in self?.animateNewestTabBehindReader() })
        animator.onCompletion = { [weak self] in self?.onDismiss?() }
        return animator
    }

    // MARK: - Reader stack

    private func setUpInnerNav() {
        let root = makePage(url: url)
        innerNav.setViewControllers([root], animated: false)
        innerNav.setNavigationBarHidden(true, animated: false)
        innerNav.delegate = self
        innerNav.interactivePopGestureRecognizer?.isEnabled = false
        addChild(innerNav)
        cardView.installContentView(innerNav.view)
        innerNav.didMove(toParent: self)
    }

    private func makePage(url: URL) -> InlineReaderPageViewController {
        let page = InlineReaderPageViewController(
            url: url, headerHeight: 0)
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
        guard !didDismiss, pendingSourcePoint == nil, !isNavigatingInlineStack else { return }
        isNavigatingInlineStack = true
        pendingSourcePoint = sourcePoint
        pendingTabInsertion = true
        let page = makePage(url: url)
        pageSourcePoints[ObjectIdentifier(page)] = sourcePoint
        innerNav.pushViewController(page, animated: true)
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
        switch operation {
        case .push:
            guard let sourcePoint = pendingSourcePoint else { return nil }
            let animator = InlineReaderEclipseAnimator(
                sourcePoint: sourcePoint, direction: .forward, sceneContainer: view,
                sceneFrame: localCardFrame
            ) { [weak self] in
                guard let self else { return }
                self.cardView.contentContainer.bringSubviewToFront(self.innerNav.view)
                self.syncHeaderToTopPage(animateNewTab: true)
            }
            pendingSourcePoint = nil
            return animator
        case .pop:
            pendingTabRemovalAnimation = true
            let sourcePoint = pageSourcePoints[ObjectIdentifier(fromVC)]
                ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            return InlineReaderEclipseAnimator(
                sourcePoint: sourcePoint,
                direction: .reverse,
                sceneContainer: view,
                sceneFrame: localCardFrame,
                atZenith: { [weak self] in self?.animateNewestTabBehindReader() })
        default:
            return nil
        }
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        pendingSourcePoint = nil
        let animateReflow = pendingTabRemovalAnimation
        pendingTabRemovalAnimation = false
        syncHeaderToTopPage(animateTabReflow: animateReflow)
        if !isAnimatingTabLayout { isNavigatingInlineStack = false }
    }

    private func syncHeaderToTopPage(
        animateNewTab: Bool = false,
        animateTabReflow: Bool = false
    ) {
        topPage?.setHeaderHeight(0)
        rebuildTabs(
            animateNewest: animateNewTab && pendingTabInsertion,
            animateReflow: animateTabReflow)
        pendingTabInsertion = false
        layoutTabBar()
        onChromeStateChanged?()
    }

    // MARK: - Header and tabs

    private func configureTabBar() {
        tabBar.backgroundColor = .clear
        view.addSubview(tabBar)

        tabScrollView.showsHorizontalScrollIndicator = false
        tabScrollView.alwaysBounceHorizontal = false
        tabScrollView.clipsToBounds = true
        tabBar.addSubview(tabScrollView)
        tabScrollView.addSubview(tabContainer)
        rebuildTabs(animateNewest: false, animateReflow: false)
    }

    private func rebuildTabs(animateNewest: Bool, animateReflow: Bool = false) {
        let ancestors = ancestorDescriptors()
        let previousFrames = Dictionary(
            uniqueKeysWithValues: tabButtons.map { (ObjectIdentifier($0), $0.frame) })
        var reusable = tabButtons
        var nextButtons: [InlineReaderTabButton] = []
        for (index, descriptor) in ancestors.enumerated() {
            let button: InlineReaderTabButton
            if let match = reusable.firstIndex(where: { $0.url == descriptor.url }) {
                button = reusable.remove(at: match)
                button.updateTitle(descriptor.title)
            } else {
                button = InlineReaderTabButton(url: descriptor.url, title: descriptor.title)
            }
            button.tag = index
            button.removeTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            button.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            tabContainer.addSubview(button)
            button.layer.zPosition = CGFloat(index)
            nextButtons.append(button)
        }
        reusable.forEach { $0.removeFromSuperview() }
        tabButtons = nextButtons
        if animateReflow, !animateNewest, !isAnimatingTabLayout {
            layoutTabs(scrollToRight: false)
            let targets = tabButtons.map(\.frame)
            for button in tabButtons {
                if let oldFrame = previousFrames[ObjectIdentifier(button)] {
                    button.frame = oldFrame
                }
            }
            isAnimatingTabLayout = true
            UIView.animate(
                withDuration: 0.3, delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState]
            ) {
                for (index, button) in self.tabButtons.enumerated()
                    where targets.indices.contains(index) {
                    button.frame = targets[index]
                }
            } completion: { _ in
                self.isAnimatingTabLayout = false
                self.isNavigatingInlineStack = false
                self.layoutTabs(scrollToRight: true)
            }
            return
        }
        guard animateNewest, let newest = tabButtons.last else {
            if !isAnimatingTabLayout { layoutTabs(scrollToRight: true) }
            return
        }

        layoutTabs(scrollToRight: false)
        let targetFrames = tabButtons.map(\.frame)
        for button in tabButtons where button !== newest {
            if let oldFrame = previousFrames[ObjectIdentifier(button)] {
                button.frame = oldFrame
            }
        }
        newest.alpha = 1
        newest.transform = CGAffineTransform(
            translationX: 0, y: Self.tabBarHeight - Self.tabBottomOverlap)
        tabContainer.layoutIfNeeded()
        isAnimatingTabLayout = true
        UIView.animate(
            withDuration: 0.38, delay: 0,
            usingSpringWithDamping: 0.82, initialSpringVelocity: 0.55
        ) {
            for (index, button) in self.tabButtons.enumerated()
                where targetFrames.indices.contains(index) {
                button.frame = targetFrames[index]
            }
            self.tabScrollView.contentOffset = CGPoint(
                x: max(
                    self.tabScrollView.contentSize.width - self.tabScrollView.bounds.width, 0),
                y: 0)
            newest.transform = .identity
        } completion: { _ in
            self.isAnimatingTabLayout = false
            self.isNavigatingInlineStack = false
            self.layoutTabs(scrollToRight: true)
        }
    }

    private func animateNewestTabBehindReader() {
        guard let newest = tabButtons.last else { return }
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            newest.alpha = 0
            newest.transform = CGAffineTransform(
                translationX: 0, y: Self.tabBarHeight - Self.tabBottomOverlap)
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

    private func layoutTabBar() {
        let inset = CarouselCardView.cornerRadius
        tabBar.frame = CGRect(
            x: inset, y: 0,
            width: max(view.bounds.width - inset * 2, 0),
            height: Self.tabBarHeight + Self.tabBottomOverlap)
        tabScrollView.frame = CGRect(
            x: 0, y: 4, width: tabBar.bounds.width,
            height: Self.tabBarHeight)
        if !isAnimatingTabLayout { layoutTabs(scrollToRight: false) }
    }

    private func layoutTabs(scrollToRight: Bool) {
        let count = tabButtons.count
        let idealWidths = tabButtons.map { $0.idealWidth }
        let metrics = InlineReaderTabMetrics(
            availableWidth: tabScrollView.bounds.width,
            idealWidths: idealWidths,
            minimumTabWidth: Self.minimumTabWidth,
            spacing: Self.tabSpacing)
        var x: CGFloat = 0
        for (index, button) in tabButtons.enumerated() {
            guard metrics.tabWidths.indices.contains(index) else { continue }
            button.frame = CGRect(
                x: x, y: 0, width: metrics.tabWidths[index],
                height: tabScrollView.bounds.height)
            x += metrics.tabWidths[index] + Self.tabSpacing
        }
        let contentWidth = metrics.contentWidth
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

    private func closeInnermostReader() {
        guard !isNavigatingInlineStack else { return }
        innerNav.view.transform = .identity
        innerNav.view.alpha = 1
        if innerNav.viewControllers.count > 1 {
            isNavigatingInlineStack = true
            innerNav.popViewController(animated: true)
        } else {
            animateDismiss()
        }
    }

    @objc private func tabTapped(_ sender: UIButton) {
        guard !isNavigatingInlineStack else { return }
        if sender.tag == 0 {
            animateDismiss()
            return
        }
        let pageIndex = sender.tag - 1
        guard innerNav.viewControllers.indices.contains(pageIndex) else { return }
        isNavigatingInlineStack = true
        innerNav.popToViewController(innerNav.viewControllers[pageIndex], animated: true)
    }

    private var presentationFrameInWindow: CGRect {
        presentationMetrics.presentationFrameInWindow
    }

    private var localCardFrame: CGRect {
        presentationMetrics.localCardFrame
    }

    private var presentationMetrics: InlineReaderPresentationMetrics {
        InlineReaderPresentationMetrics(
            cardFrameInWindow: cardFrameInWindow, tabHeight: Self.tabBarHeight)
    }

    // MARK: - Stable outer chrome target

    public var chromeState: ReaderChromeState? {
        guard let page = topPage else { return nil }
        return ReaderChromeState(
            isArticle: page.isArticle,
            modes: Self.orderedModes,
            selectedMode: page.readerMode,
            isAudioOn: page.isAudioOn,
            showsBack: true,
            offersSaveShare: shareProvider != nil,
            isSaved: false)
    }

    public func chromeSetMode(_ mode: ReadingListItem.ReaderMode) {
        topPage?.setMode(mode)
        onChromeStateChanged?()
    }

    public func chromeToggleAudio() {
        topPage?.toggleAudio()
        onChromeStateChanged?()
    }

    public func chromeSave() {}
    public func chromeShare(from sourceView: UIView) {
        guard let page = topPage else { return }
        shareProvider?.presentShareSheet(
            urlString: page.url.absoluteString, title: page.displayTitle,
            from: self, sourceView: sourceView)
    }
    public func chromeBack() { closeInnermostReader() }

    fileprivate func forwardPersistentChromeTap(at windowPoint: CGPoint) {
        let width = UIScreen.main.bounds.width
        if windowPoint.x < 78 {
            chromeBack()
            return
        }
        if windowPoint.x > width - 78 {
            chromeToggleAudio()
            return
        }
        guard let state = chromeState, !state.modes.isEmpty else { return }
        let controlWidth = min(CGFloat(state.modes.count) * 44, width - 176)
        let minX = (width - controlWidth) / 2
        guard windowPoint.x >= minX, windowPoint.x <= minX + controlWidth else { return }
        let fraction = (windowPoint.x - minX) / max(controlWidth, 1)
        let index = min(Int(fraction * CGFloat(state.modes.count)), state.modes.count - 1)
        chromeSetMode(state.modes[index])
    }
}

private final class InlineReaderPresentationController: UIPresentationController {
    private let cardFrameInWindow: CGRect
    private let presentationFrameInWindow: CGRect
    private let showsOuterContentBelow: Bool
    private weak var topChromeProxy: UIView?
    private weak var shareProxy: UIButton?
    private weak var outerContentBlur: UIVisualEffectView?

    init(presentedViewController: UIViewController, presenting: UIViewController?,
         cardFrameInWindow: CGRect, presentationFrameInWindow: CGRect,
         showsOuterContentBelow: Bool) {
        self.cardFrameInWindow = cardFrameInWindow
        self.presentationFrameInWindow = presentationFrameInWindow
        self.showsOuterContentBelow = showsOuterContentBelow
        super.init(presentedViewController: presentedViewController, presenting: presenting)
    }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else { return presentationFrameInWindow }
        return containerView.convert(presentationFrameInWindow, from: nil)
    }

    override var shouldRemovePresentersView: Bool { false }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        super.presentationTransitionDidEnd(completed)
        guard completed, let containerView,
              let overlay = presentedViewController as? SplitWebOverlayViewController
        else { return }

        let cardFrame = containerView.convert(cardFrameInWindow, from: nil)
        let presentationFrame = containerView.convert(presentationFrameInWindow, from: nil)
        if showsOuterContentBelow {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            blur.alpha = 0.14
            blur.isUserInteractionEnabled = false
            blur.frame = CGRect(
                x: cardFrame.minX, y: cardFrame.maxY,
                width: cardFrame.width,
                height: max(containerView.bounds.maxY - cardFrame.maxY, 0))
            containerView.insertSubview(blur, belowSubview: presentedViewController.view)
            outerContentBlur = blur
        }

        let topProxy = UIView(frame: CGRect(
            x: 0, y: 0, width: containerView.bounds.width,
            height: max(presentationFrame.minY, 0)))
        topProxy.backgroundColor = .clear
        topProxy.addGestureRecognizer(UITapGestureRecognizer(
            target: self, action: #selector(forwardTopChromeTap(_:))))
        containerView.addSubview(topProxy)
        topChromeProxy = topProxy

        let shareProxy = UIButton(type: .custom)
        shareProxy.backgroundColor = .clear
        shareProxy.frame = CGRect(
            x: max(containerView.bounds.maxX - 92, 0), y: cardFrame.maxY,
            width: min(92, containerView.bounds.width),
            height: max(containerView.bounds.maxY - cardFrame.maxY, 0))
        shareProxy.addAction(UIAction { [weak overlay, weak shareProxy] _ in
            guard let overlay, let shareProxy else { return }
            overlay.chromeShare(from: shareProxy)
        }, for: .touchUpInside)
        containerView.addSubview(shareProxy)
        self.shareProxy = shareProxy
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        guard let containerView else { return }
        let cardFrame = containerView.convert(cardFrameInWindow, from: nil)
        let presentationFrame = containerView.convert(presentationFrameInWindow, from: nil)
        outerContentBlur?.frame = CGRect(
            x: cardFrame.minX, y: cardFrame.maxY,
            width: cardFrame.width,
            height: max(containerView.bounds.maxY - cardFrame.maxY, 0))
        topChromeProxy?.frame = CGRect(
            x: 0, y: 0, width: containerView.bounds.width,
            height: max(presentationFrame.minY, 0))
        shareProxy?.frame = CGRect(
            x: max(containerView.bounds.maxX - 92, 0), y: cardFrame.maxY,
            width: min(92, containerView.bounds.width),
            height: max(containerView.bounds.maxY - cardFrame.maxY, 0))
        presentedView?.frame = frameOfPresentedViewInContainerView
    }

    @objc private func forwardTopChromeTap(_ recognizer: UITapGestureRecognizer) {
        guard let containerView,
              let overlay = presentedViewController as? SplitWebOverlayViewController
        else { return }
        overlay.forwardPersistentChromeTap(
            at: containerView.convert(recognizer.location(in: containerView), to: nil))
    }
}

private final class InlineReaderTabButton: UIButton {
    let url: URL
    private let faviconView = CarouselSourceBadgeView()
    private let titleLabelView = UILabel()
    private var faviconTask: Task<Void, Never>?
    private var hasFetchedFavicon = false
    private let edgeView = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let edgeMaskView = UIView()
    private let edgeMask = CAShapeLayer()
    private let edgeHighlight = CAShapeLayer()
    private let tabShapeMask = CAShapeLayer()

    var idealWidth: CGFloat {
        8 + 18 + 6 + ceil(titleLabelView.intrinsicContentSize.width) + 12
    }

    init(url: URL, title: String) {
        self.url = url
        super.init(frame: .zero)
        accessibilityLabel = "Return to \(title)"
        backgroundColor = .systemBackground
        clipsToBounds = false
        layer.mask = tabShapeMask

        edgeView.isUserInteractionEnabled = false
        edgeMask.fillColor = UIColor.white.cgColor
        edgeMaskView.layer.addSublayer(edgeMask)
        edgeView.mask = edgeMaskView
        edgeHighlight.fillColor = UIColor.clear.cgColor
        edgeHighlight.strokeColor = GlassStyle.glassBorderColor.cgColor
        edgeHighlight.lineWidth = 0.8
        edgeView.contentView.layer.addSublayer(edgeHighlight)
        addSubview(edgeView)

        faviconView.setBadge(.symbol("globe.fill"))
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
            await MainActor.run {
                self?.hasFetchedFavicon = true
                self?.faviconView.setBadge(.icon(image))
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit { faviconTask?.cancel() }

    func updateTitle(_ title: String) {
        accessibilityLabel = "Return to \(title)"
        titleLabelView.text = title
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        edgeView.frame = bounds
        edgeMaskView.frame = bounds
        edgeMask.frame = bounds
        edgeHighlight.frame = bounds
        let radius: CGFloat = min(17, bounds.height * 0.48)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: bounds.maxY + 2))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addCurve(
            to: CGPoint(x: radius, y: 0),
            controlPoint1: CGPoint(x: 0, y: radius * 0.35),
            controlPoint2: CGPoint(x: radius * 0.35, y: 0))
        path.addLine(to: CGPoint(x: bounds.maxX - radius, y: 0))
        path.addCurve(
            to: CGPoint(x: bounds.maxX, y: radius),
            controlPoint1: CGPoint(x: bounds.maxX - radius * 0.35, y: 0),
            controlPoint2: CGPoint(x: bounds.maxX, y: radius * 0.35))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY + 2))
        edgeHighlight.path = path.cgPath
        let fillPath = UIBezierPath(cgPath: path.cgPath)
        fillPath.addLine(to: CGPoint(x: 0, y: bounds.maxY + 2))
        fillPath.close()
        tabShapeMask.frame = bounds
        tabShapeMask.path = fillPath.cgPath
        tabShapeMask.fillColor = UIColor.black.cgColor
        edgeMask.path = path.cgPath
        edgeMask.fillColor = UIColor.clear.cgColor
        edgeMask.strokeColor = UIColor.white.cgColor
        edgeMask.lineWidth = 3
        let iconSide: CGFloat = 18
        let leading: CGFloat = 8
        faviconView.frame = CGRect(
            x: leading, y: (bounds.height - iconSide) / 2,
            width: iconSide, height: iconSide)
        if !hasFetchedFavicon {
            // The badge was configured before it had bounds; refresh the symbol
            // now so the fallback is favicon-sized rather than a tiny dot.
            faviconView.setBadge(.symbol("globe.fill"))
        }
        let titleX = faviconView.frame.maxX + 6
        titleLabelView.frame = CGRect(
            x: titleX, y: 0,
            width: max(bounds.width - titleX - 7, 0), height: bounds.height)
        titleLabelView.isHidden = bounds.width < 60
    }
}
