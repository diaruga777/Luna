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
    private let contentTop: CGFloat

    private let innerNav = UINavigationController()
    private let tabBar = UIView()
    private let tabScrollView = UIScrollView()
    private let tabContainer = UIView()

    private static let tabBarHeight: CGFloat = 42
    private static let tabInset: CGFloat = 8
    private static let tabSpacing: CGFloat = 5
    private static let minimumTabWidth: CGFloat = 38
    private static let orderedModes: [ReadingListItem.ReaderMode] = [.scroll, .rsvp, .original]

    private var didDismiss = false
    private var pendingSourcePoint: CGPoint?
    private var pendingTabInsertion = false
    private var pageSourcePoints: [ObjectIdentifier: CGPoint] = [:]
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
        outerTitle: String? = nil,
        contentTop: CGFloat = 0
    ) {
        self.url = url
        self.initialSourcePoint = sourcePoint ?? CGPoint(x: UIScreen.main.bounds.midX, y: cutY)
        self.outerURL = outerURL ?? url
        self.outerTitle = Self.titleFallback(outerTitle, url: outerURL ?? url)
        self.contentTop = max(contentTop, 0)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        transitioningDelegate = self
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setUpInnerNav()
        configureTabBar()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = min(contentTop, view.bounds.maxY)
        innerNav.view.frame = CGRect(x: 0, y: top, width: view.bounds.width,
                                     height: max(view.bounds.height - top, 0))
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
            presentedViewController: presented, presenting: presenting)
    }

    public func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        InlineReaderEclipseAnimator(
            sourcePoint: initialSourcePoint,
            direction: .forward,
            sceneFrame: eclipseFrame,
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
            sceneFrame: eclipseFrame,
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
        view.addSubview(innerNav.view)
        innerNav.didMove(toParent: self)
    }

    private func makePage(url: URL) -> InlineReaderPageViewController {
        let page = InlineReaderPageViewController(
            url: url, headerHeight: Self.tabBarHeight)
        page.onLinkActivatedAtPoint = { [weak self, weak page] linkURL, point in
            guard let self, let page else { return }
            let converted = page.view.convert(point, to: self.view)
            self.pushPage(url: linkURL, sourcePoint: converted)
        }
        page.onBecameArticle = { [weak self] in self?.syncHeaderToTopPage() }
        page.onMetadataChanged = { [weak self] in self?.syncHeaderToTopPage() }
        page.onOverscrollDismiss = { [weak self] in self?.closeInnermostReader() }
        page.onOverscrollProgress = { [weak self] progress, direction in
            self?.applyOverscroll(progress: progress, direction: direction)
        }
        return page
    }

    private func pushPage(url: URL, sourcePoint: CGPoint) {
        guard !didDismiss, pendingSourcePoint == nil else { return }
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
                sceneFrame: eclipseFrame
            ) { [weak self] in
                guard let self else { return }
                self.view.bringSubviewToFront(self.innerNav.view)
                self.innerNav.view.bringSubviewToFront(self.tabBar)
                self.syncHeaderToTopPage(animateNewTab: true)
            }
            pendingSourcePoint = nil
            return animator
        case .pop:
            let sourcePoint = pageSourcePoints[ObjectIdentifier(fromVC)]
                ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            return InlineReaderEclipseAnimator(
                sourcePoint: sourcePoint,
                direction: .reverse,
                sceneContainer: view,
                sceneFrame: eclipseFrame,
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
        syncHeaderToTopPage()
    }

    private func syncHeaderToTopPage(animateNewTab: Bool = false) {
        topPage?.setHeaderHeight(Self.tabBarHeight)
        rebuildTabs(animateNewest: animateNewTab && pendingTabInsertion)
        pendingTabInsertion = false
        layoutTabBar()
        onChromeStateChanged?()
    }

    // MARK: - Header and tabs

    private func configureTabBar() {
        tabBar.backgroundColor = GlassStyle.solidBarColor
        tabBar.layer.shadowColor = UIColor.black.cgColor
        tabBar.layer.shadowOpacity = 0.08
        tabBar.layer.shadowRadius = 8
        tabBar.layer.shadowOffset = CGSize(width: 0, height: 3)
        innerNav.view.addSubview(tabBar)

        tabScrollView.showsHorizontalScrollIndicator = false
        tabScrollView.alwaysBounceHorizontal = false
        tabScrollView.clipsToBounds = true
        tabBar.addSubview(tabScrollView)
        tabScrollView.addSubview(tabContainer)
        rebuildTabs(animateNewest: false)
    }

    private func rebuildTabs(animateNewest: Bool) {
        let ancestors = ancestorDescriptors()
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
            nextButtons.append(button)
        }
        reusable.forEach { $0.removeFromSuperview() }
        tabButtons = nextButtons
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

    private func animateNewestTabBehindReader() {
        guard let newest = tabButtons.last else { return }
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            newest.alpha = 0
            newest.transform = CGAffineTransform(translationX: 0, y: 18)
                .scaledBy(x: 0.86, y: 0.86)
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
        tabBar.frame = CGRect(x: 0, y: 0, width: innerNav.view.bounds.width,
                              height: Self.tabBarHeight)
        tabScrollView.frame = tabBar.bounds.insetBy(dx: Self.tabInset, dy: 4)
        layoutTabs(scrollToRight: false)
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

    private func closeInnermostReader() {
        innerNav.view.transform = .identity
        innerNav.view.alpha = 1
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

    private var eclipseFrame: CGRect {
        CGRect(x: 0, y: contentTop, width: view.bounds.width,
               height: max(view.bounds.height - contentTop, 0))
    }

    private func applyOverscroll(progress: CGFloat, direction: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        let travel = min(innerNav.view.bounds.height * 0.08, 48) * clamped * direction
        innerNav.view.transform = CGAffineTransform(translationX: 0, y: travel)
        innerNav.view.alpha = 1 - clamped * 0.16
        if clamped == 0 {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
                self.innerNav.view.transform = .identity
                self.innerNav.view.alpha = 1
            }
        }
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
            offersSaveShare: false,
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
    public func chromeShare(from sourceView: UIView) {}
    public func chromeBack() { closeInnermostReader() }
}

private final class InlineReaderPresentationController: UIPresentationController {
    override var frameOfPresentedViewInContainerView: CGRect {
        containerView?.bounds ?? .zero
    }

    override var shouldRemovePresentersView: Bool { false }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = frameOfPresentedViewInContainerView
    }
}

private final class InlineReaderTabButton: UIButton {
    let url: URL
    private let faviconView = CarouselSourceBadgeView()
    private let titleLabelView = UILabel()
    private var faviconTask: Task<Void, Never>?
    private var hasFetchedFavicon = false

    init(url: URL, title: String) {
        self.url = url
        super.init(frame: .zero)
        accessibilityLabel = "Return to \(title)"
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.82)
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        clipsToBounds = true

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
