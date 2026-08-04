//
//  SplitWebOverlayViewController.swift
//  LunaReaderUI
//

import LunaDesignSystem
import LunaFetch
import LunaModels
import LunaStorage
import UIKit

/// Where a nested reader appears — the one decision that separates the phone's
/// inline reader from the iPad's.
public enum InlineReaderPlacement: Equatable, Sendable {
    /// Over the reader it came from, its ancestors reduced to a tab strip. The
    /// only thing that fits on a phone: one column of readable width.
    case overlay
    /// Its own card, beside the reader it came from, on a container with room
    /// for two columns. The outer card steps left and keeps every touch; this
    /// one takes the right column and stacks its own nested layers there.
    ///
    /// A column is a CHILD of its host, not a modal presentation: a
    /// presentation container is a full-screen view that swallows every touch
    /// outside the presented frame, which is exactly the touches the card next
    /// door needs.
    case column
}

/// Optional bridge implemented by containers such as the root card carousel.
/// It lets an embedded reader dismiss its surrounding card chrome in lockstep
/// with the eclipse without coupling LunaReaderUI to the app target.
public protocol InlineReaderPresentationCoordinating: AnyObject {
    /// The stable host chrome should begin controlling `reader`.
    func inlineReaderWillPresent(_ reader: ReaderChromeControlling)
    /// Restore the outer reader as the stable chrome's target.
    func inlineReaderDidDismiss(_ reader: ReaderChromeControlling)
    /// Begin any visual restoration that should accompany the reverse eclipse.
    /// Stable ownership still changes only in `inlineReaderDidDismiss`.
    func inlineReaderWillDismiss(_ reader: ReaderChromeControlling)
    /// Put dismissal visuals back if UIKit cancels the reverse transition.
    func inlineReaderDismissalDidCancel(_ reader: ReaderChromeControlling)
    /// Top edge of the existing reader card in window coordinates.
    var inlineReaderTopEdgeInWindow: CGFloat { get }
    /// Resting reader-card frame in window coordinates.
    var inlineReaderCardFrameInWindow: CGRect { get }
    /// Whether the outer reader is scrollable content that remains visible below.
    var inlineReaderShowsOuterContentBelow: Bool { get }

    /// Whether this host has room to open the nested reader beside the outer one
    /// rather than over it. Hosts that don't implement it stay on `.overlay`.
    var inlineReaderPlacement: InlineReaderPlacement { get }

    /// Take ownership of `reader` as the column beside the outer one: install it
    /// as a child at the right column's frame, step the outer card aside, and
    /// run its opening eclipse. Only ever called on a host that answered
    /// `.column`.
    func inlineReaderPresentAsColumn(
        _ reader: SplitWebOverlayViewController, fromSourcePointInWindow point: CGPoint)

    /// The open column asked to go away (its innermost layer was the last one).
    /// The host runs the closing eclipse, removes the child, and brings the
    /// outer card back to center.
    func inlineReaderColumnRequestedClose(_ reader: SplitWebOverlayViewController)

    /// A link activated in the OUTER reader while a column is already open
    /// belongs on that column's stack — nested layers stack on the second card,
    /// they never open a third. False when no column is open, leaving the caller
    /// to open one.
    func inlineReaderPushIntoOpenColumn(url: URL, sourcePointInWindow point: CGPoint) -> Bool
}

public extension InlineReaderPresentationCoordinating {
    func inlineReaderWillDismiss(_ reader: ReaderChromeControlling) {}
    func inlineReaderDismissalDidCancel(_ reader: ReaderChromeControlling) {}
    var inlineReaderPlacement: InlineReaderPlacement { .overlay }
    func inlineReaderPresentAsColumn(
        _ reader: SplitWebOverlayViewController, fromSourcePointInWindow point: CGPoint) {}
    func inlineReaderColumnRequestedClose(_ reader: SplitWebOverlayViewController) {}
    func inlineReaderPushIntoOpenColumn(url: URL, sourcePointInWindow point: CGPoint) -> Bool {
        false
    }
}

/// The single door a nested reader is opened through.
///
/// Three readers can activate a link (the rabbit-hole layers in a card, a
/// standalone scroll reader, RSVP's link pill), and the choice between an
/// overlay and a second column belongs to the HOST's width, not to any of them.
/// Routing it here keeps that decision in one place — three copies of it is
/// exactly how a phone-only behaviour survives on the iPad.
@MainActor
public enum InlineReaderOpener {
    /// Opens `url` as a nested reader. Returns the overlay when one was created,
    /// so a caller with cleanup of its own (the scroll reader's saved offset) can
    /// still attach it. Nil when the link went onto an already-open column.
    @discardableResult
    public static func open(
        url: URL,
        from host: UIViewController,
        coordinator: InlineReaderPresentationCoordinating?,
        shareProvider: ReaderShareProviding?,
        sourcePointInWindow: CGPoint,
        outerURL: URL,
        outerTitle: String?,
        onDismiss: (() -> Void)? = nil
    ) -> SplitWebOverlayViewController? {
        // A column already open beside the outer reader takes the link: nested
        // layers stack on the second card, they never open a third.
        if coordinator?.inlineReaderPushIntoOpenColumn(
            url: url, sourcePointInWindow: sourcePointInWindow) == true {
            return nil
        }
        let placement = coordinator?.inlineReaderPlacement ?? .overlay
        guard placement == .column || host.presentedViewController == nil else { return nil }
        let overlay = SplitWebOverlayViewController(
            url: url,
            shareProvider: shareProvider,
            sourcePoint: sourcePointInWindow,
            outerURL: outerURL,
            outerTitle: outerTitle,
            contentTop: coordinator?.inlineReaderTopEdgeInWindow ?? 0,
            cardFrame: coordinator?.inlineReaderCardFrameInWindow,
            // A column has nothing below it — the room under the card belongs to
            // the deck's own chrome, not to the reader it opened from.
            showsOuterContentBelow: placement == .column
                ? false
                : (coordinator?.inlineReaderShowsOuterContentBelow ?? false),
            placement: placement)
        overlay.presentationCoordinator = coordinator
        overlay.onDismiss = onDismiss
        switch placement {
        case .overlay:
            host.present(overlay, animated: true)
        case .column:
            coordinator?.inlineReaderPresentAsColumn(
                overlay, fromSourcePointInWindow: sourcePointInWindow)
        }
        return overlay
    }
}

extension UIViewController {
    /// Walks `parent` for the nearest ancestor conforming to
    /// `InlineReaderPresentationCoordinating` — the shared "find my host" lookup used
    /// by every reader that can open a nested `SplitWebOverlayViewController`.
    var inlineReaderPresentationCoordinator: InlineReaderPresentationCoordinating? {
        var ancestor = parent
        while let controller = ancestor {
            if let coordinator = controller as? InlineReaderPresentationCoordinating {
                return coordinator
            }
            ancestor = controller.parent
        }
        return nil
    }
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

    /// The stable outer chrome this overlay opens/chrome-state-changes/dismisses
    /// against — set by whichever reader creates the overlay (typically via
    /// `inlineReaderPresentationCoordinator`, the shared ancestor-walk below).
    public weak var presentationCoordinator: InlineReaderPresentationCoordinating?
    /// One-shot hook run when dismissal completes, for cleanup local to the overlay's
    /// creator rather than the outer chrome (e.g. `ScrollReaderViewController`
    /// restoring the scroll offset it had before the split opened). Fires exactly once.
    public var onDismiss: (() -> Void)?

    private let url: URL
    private let initialSourcePoint: CGPoint
    private let outerURL: URL
    private let outerTitle: String
    private let cardFrameInWindow: CGRect
    private let shareProvider: ReaderShareProviding?
    private let showsOuterContentBelow: Bool

    /// Over the outer reader, or beside it. Fixed at construction: the host
    /// decides from its own width before the reader exists.
    public let placement: InlineReaderPlacement
    private var isColumn: Bool { placement == .column }

    private let innerNav = UINavigationController()
    private let cardView = CardSurfaceView()
    private let tabBar = UIView()
    private let tabScrollView = UIScrollView()
    private let tabContainer = UIView()
    private let scrollIndicator = HorizonScrollIndicator.makeHosted()
    /// A column carries its OWN controls: the shared screen-level chrome stays
    /// with the card next door, which is still being read. Nil in `.overlay`.
    private var columnChrome: InlineReaderColumnChromeBar?

    private static let tabBarHeight: CGFloat = 42
    private static let tabBottomOverlap: CGFloat = 4
    private static let tabSpacing: CGFloat = -9
    private static let minimumTabWidth: CGFloat = 38
    private static let orderedModes: [ReadingListItem.ReaderMode] = [.scroll, .rsvp, .original]

    private var didDismiss = false
    private var didNotifyDismissal = false
    private var pendingSourcePoint: CGPoint?
    private var pendingTabInsertion = false
    private var pageSourcePoints: [ObjectIdentifier: CGPoint] = [:]
    private var tabButtons: [InlineReaderTabButton] = []
    private var isAnimatingTabLayout = false
    private var isNavigatingInlineStack = false
    private var pendingTabRemovalAnimation = false

    public init(
        url: URL,
        shareProvider: ReaderShareProviding?,
        sourcePoint: CGPoint,
        outerURL: URL? = nil,
        outerTitle: String? = nil,
        contentTop: CGFloat = 0,
        cardFrame: CGRect? = nil,
        showsOuterContentBelow: Bool = false,
        placement: InlineReaderPlacement = .overlay
    ) {
        self.url = url
        self.initialSourcePoint = sourcePoint
        self.outerURL = outerURL ?? url
        self.outerTitle = Self.titleFallback(outerTitle, url: outerURL ?? url)
        self.shareProvider = shareProvider
        self.showsOuterContentBelow = showsOuterContentBelow
        self.placement = placement
        self.cardFrameInWindow = cardFrame ?? CGRect(
            x: 0, y: max(contentTop, 0), width: UIScreen.main.bounds.width,
            height: max(UIScreen.main.bounds.height - max(contentTop, 0), 0))
        super.init(nibName: nil, bundle: nil)
        guard placement == .overlay else { return }
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
        scrollIndicator.isHidden = true
        view.addSubview(scrollIndicator)
        setUpInnerNav()
        if isColumn { installColumnChrome() }
        // `setUpInnerNav` may synchronously load a cached page and publish its
        // scroll view. Install the hosted indicator first, then make one final
        // idempotent sweep so that target cannot be hidden after publication.
        updateScrollIndicatorTarget()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        cardView.frame = localCardFrame
        innerNav.view.frame = cardView.contentContainer.bounds
        layoutTabBar()
        layoutScrollIndicator()
        layoutColumnChrome()
    }

    private func transitionWillOpen() {
        SharedDiagnosticLog.record(
            "opening inline reader: \(url.absoluteString)", category: "preload-tap")
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        // A column never takes the host's chrome: the card it opened beside is
        // still being read and keeps every control it had. This one drew its own.
        guard !isColumn else { return }
        presentationCoordinator?.inlineReaderWillPresent(self)
    }

    private func animateDismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        guard !isColumn else {
            // A column is a child, not a presentation: its host owns the closing
            // eclipse, the child removal, and returning the outer card to center.
            presentationCoordinator?.inlineReaderColumnRequestedClose(self)
            return
        }
        dismiss(animated: true)
    }

    // MARK: - Column lifecycle (a child, not a presentation)

    /// Runs the opening eclipse over this column's own card. Called by the host
    /// once the overlay is installed as a child and has its frame.
    public func animateColumnAppearance(completion: (() -> Void)? = nil) {
        view.layoutIfNeeded()
        transitionWillOpen()
        let scene = InlineReaderEclipseScene(
            container: view,
            sourcePoint: view.convert(initialSourcePoint, from: nil),
            frame: localCardFrame)
        cardView.alpha = 0
        tabBar.alpha = 0
        scene.animate(atZenith: { [weak self] in
            guard let self else { return }
            self.pendingTabInsertion = true
            self.tabBar.alpha = 1
            self.syncHeaderToTopPage(animateNewTab: true)
            UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut]) {
                self.cardView.alpha = 1
            }
        }, completion: { completion?() })
    }

    /// Runs the closing eclipse in reverse and calls back once the column can be
    /// removed from its host.
    public func animateColumnDismissal(completion: @escaping () -> Void) {
        let scene = InlineReaderEclipseScene(
            container: view,
            sourcePoint: view.convert(initialSourcePoint, from: nil),
            frame: localCardFrame)
        scene.animateReverse(
            hiding: cardView,
            atZenith: { [weak self] in
                self?.tabBar.alpha = 0
                self?.animateNewestTabBehindReader()
            },
            completion: { [weak self] in
                self?.onDismiss?()
                completion()
            })
    }

    fileprivate func presentationDidDismiss() {
        guard !didNotifyDismissal else { return }
        didNotifyDismissal = true
        onDismiss?()
        presentationCoordinator?.inlineReaderDidDismiss(self)
        // Async WebKit/title work may finish after UIKit has removed the
        // presentation. It must never reclaim the shared outer chrome target.
        presentationCoordinator = nil
    }

    fileprivate func presentationDismissalDidCancel() {
        didDismiss = false
        presentationCoordinator?.inlineReaderDismissalDidCancel(self)
    }

    // MARK: - Modal eclipse presentation

    public func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        InlineReaderPresentationController(
            presentedViewController: presented, presenting: presenting,
            cardFrameInWindow: inlineCardFrameInWindow,
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
            sceneFrame: inlineCardFrameInWindow,
            onTransitionStart: { [weak self] in self?.transitionWillOpen() },
            atZenith: { [weak self] in
                guard let self else { return }
                self.pendingTabInsertion = true
                self.syncHeaderToTopPage(animateNewTab: true)
            })
    }

    public func animationController(forDismissed dismissed: UIViewController)
        -> UIViewControllerAnimatedTransitioning? {
        return InlineReaderEclipseAnimator(
            sourcePoint: initialSourcePoint,
            direction: .reverse,
            sceneFrame: inlineCardFrameInWindow,
            onTransitionStart: { [weak self] in
                guard let self else { return }
                self.presentationCoordinator?.inlineReaderWillDismiss(self)
            },
            atZenith: { [weak self] in self?.animateNewestTabBehindReader() })
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
        page.delegate = self
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
        notifyChromeStateChanged()
        updateScrollIndicatorTarget()
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
        newest.setNeedsLayout()
        newest.layoutIfNeeded()
        newest.transform = CGAffineTransform(
            translationX: 0, y: Self.tabBarHeight - Self.tabBottomOverlap)
        tabContainer.layoutIfNeeded()
        isAnimatingTabLayout = true
        UIView.animate(
            withDuration: 0.38, delay: 0,
            usingSpringWithDamping: 0.82, initialSpringVelocity: 0.55
        ) {
            for (index, button) in self.tabButtons.enumerated()
                where button !== newest && targetFrames.indices.contains(index) {
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
        let inset = CardSurfaceView.cornerRadius
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
        return url.host?.replacingOccurrences(of: "www.", with: "")
            ?? L10n.string("Reader")
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

    private var inlineCardFrameInWindow: CGRect {
        presentationMetrics.cardFrameInWindow
    }

    /// Bakes the eclipse corona for the geometry a reader opened from
    /// `cardFrameInWindow` will use — the card footprint minus the tab strip,
    /// which is a different size from the carousel's own card corona and so a
    /// separate cache entry. Call it once the resting card frame is known so the
    /// first article open doesn't render it mid-transition.
    @MainActor
    public static func prewarmEclipseCorona(cardFrameInWindow: CGRect) {
        let metrics = InlineReaderPresentationMetrics(
            cardFrameInWindow: cardFrameInWindow, tabHeight: tabBarHeight)
        EclipseCorona.prewarm(
            bodySize: metrics.localCardFrame.size,
            // `CardEclipseTransition.makeCorona` always uses the carousel card's
            // radius, whatever the body it surrounds.
            cornerRadius: CarouselCardView.cornerRadius,
            tint: LunaSurfacePalette.atmosphereTint)
    }

    private var presentationMetrics: InlineReaderPresentationMetrics {
        // A column is a child view: its host owns its frame and may resize it
        // (rotation, a Split View resize), so the geometry comes from the live
        // bounds rather than the window rect captured when the link was tapped.
        // An overlay's presentation frame must stay the captured one — it is what
        // the presentation controller was built with.
        guard isColumn, isViewLoaded, view.bounds.width > 0 else {
            return InlineReaderPresentationMetrics(
                cardFrameInWindow: cardFrameInWindow, tabHeight: Self.tabBarHeight)
        }
        return InlineReaderPresentationMetrics(
            cardFrameInWindow: view.convert(view.bounds, to: nil),
            tabHeight: Self.tabBarHeight)
    }

    // MARK: - Column chrome

    /// Every control the column needs, in one floating glass bar inside its
    /// card's bottom edge: close, the Scroll/RSVP/Original switcher, read-aloud,
    /// share. It goes at the BOTTOM deliberately — the top of a reader is where
    /// the first line is, and the deck already puts its own switcher in the
    /// bottom lane while reading.
    private func installColumnChrome() {
        let bar = InlineReaderColumnChromeBar()
        bar.onClose = { [weak self] in self?.chromeBack() }
        bar.onToggleAudio = { [weak self] in self?.chromeToggleAudio() }
        bar.onSelectMode = { [weak self] mode in self?.chromeSetMode(mode) }
        bar.shareMenu = { [weak self] source in self?.chromeShareMenu(from: source) }
        bar.onShare = { [weak self] source in self?.chromeShare(from: source) }
        view.addSubview(bar)
        columnChrome = bar
        bar.apply(chromeState, providesShareMenu: providesShareMenu)
    }

    private func layoutColumnChrome() {
        guard let columnChrome else { return }
        let card = localCardFrame
        let size = columnChrome.sizeThatFits(CGSize(width: card.width - 24, height: 0))
        columnChrome.frame = CGRect(
            x: card.midX - size.width / 2,
            y: card.maxY - size.height - 14,
            width: size.width,
            height: size.height)
    }

    /// Pushes a link the OUTER reader activated onto this column's stack. The
    /// point is in window coordinates — the eclipse grows from the link the user
    /// actually touched, one card over.
    public func pushLink(url: URL, sourcePointInWindow point: CGPoint) {
        guard isColumn, !didDismiss else { return }
        pushPage(url: url, sourcePoint: view.convert(point, from: nil))
    }

    /// Whether this column can take another link right now — false while it is
    /// already animating one in or out.
    public var acceptsPushedLink: Bool {
        isColumn && !didDismiss && pendingSourcePoint == nil && !isNavigatingInlineStack
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
            offersSaveShare: shareProvider != nil)
    }

    public func chromeSetMode(_ mode: ReadingListItem.ReaderMode) {
        topPage?.setMode(mode)
        notifyChromeStateChanged()
        updateScrollIndicatorTarget()
    }

    public func chromeToggleAudio() {
        topPage?.toggleAudio()
        notifyChromeStateChanged()
        updateScrollIndicatorTarget()
    }

    public func chromeShare(from sourceView: UIView) {
        guard let page = topPage else { return }
        shareProvider?.presentShareSheet(
            urlString: page.url.absoluteString, title: page.displayTitle,
            from: self, sourceView: sourceView)
    }

    public func chromeShareMenu(from sourceView: UIView) -> UIMenu? {
        guard let page = topPage else { return nil }
        return shareProvider?.shareMenu(
            urlString: page.url.absoluteString, title: page.displayTitle,
            from: self, sourceView: sourceView)
    }

    /// Whether the share pill should present a menu at all — false with no provider,
    /// or with one whose share is a single verb.
    public var providesShareMenu: Bool { shareProvider?.providesShareMenu == true }
    public func chromeBack() { closeInnermostReader() }

    private func notifyChromeStateChanged() {
        guard !didDismiss else { return }
        guard !isColumn else {
            columnChrome?.apply(chromeState, providesShareMenu: providesShareMenu)
            return
        }
        presentationCoordinator?.inlineReaderWillPresent(self)
    }

    private func updateScrollIndicatorTarget() {
        let scrollView = topPage?.contentScrollView
        scrollIndicator.track(scrollView)
        scrollIndicator.isHidden = scrollView == nil
        layoutScrollIndicator()
    }

    private func layoutScrollIndicator() {
        let width = HorizonScrollIndicator.bloomDiameter
        scrollIndicator.frame = CGRect(
            x: localCardFrame.maxX - width,
            y: localCardFrame.minY,
            width: width,
            height: localCardFrame.height)
        scrollIndicator.trackInsets = UIEdgeInsets(
            top: 28, left: 0, bottom: 28, right: 0)
    }

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

extension SplitWebOverlayViewController: InlineReaderPageDelegate {
    public func page(_ page: InlineReaderPageViewController, didActivateLink url: URL, at point: CGPoint) {
        let converted = page.view.convert(point, to: view)
        pushPage(url: url, sourcePoint: converted)
    }

    public func pageDidBecomeArticle(_ page: InlineReaderPageViewController) {
        syncHeaderToTopPage()
    }

    public func pageDidChangeMetadata(_ page: InlineReaderPageViewController) {
        syncHeaderToTopPage()
    }

    public func pageDidChangeContentScrollView(_ page: InlineReaderPageViewController) {
        guard topPage === page else { return }
        updateScrollIndicatorTarget()
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

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        super.dismissalTransitionDidEnd(completed)
        guard let overlay = presentedViewController as? SplitWebOverlayViewController else { return }
        guard completed else {
            overlay.presentationDismissalDidCancel()
            return
        }
        // Presentation controllers remain retained through this callback. An
        // animator may be released synchronously by `completeTransition`, so it
        // must not own restoration of the outer chrome/scroll-indicator target.
        overlay.presentationDidDismiss()
    }

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
        ShareButtonMenu.install(
            on: shareProxy,
            providesMenu: overlay.providesShareMenu,
            build: { [weak overlay, weak shareProxy] in
                guard let overlay, let shareProxy else { return nil }
                return overlay.chromeShareMenu(from: shareProxy)
            },
            fallback: { [weak overlay, weak shareProxy] in
                guard let overlay, let shareProxy else { return }
                overlay.chromeShare(from: shareProxy)
            })
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

/// The column's own controls, in one floating glass bar: close, mode switcher,
/// read-aloud, share.
///
/// The deck's screen-level pill row can't be borrowed here — it belongs to the
/// card next door, which is still being read, and read-aloud in particular has
/// to be reachable on BOTH cards for the "playing one pauses the other" rule to
/// mean anything.
private final class InlineReaderColumnChromeBar: UIView {
    var onClose: (() -> Void)?
    var onToggleAudio: (() -> Void)?
    var onSelectMode: ((ReadingListItem.ReaderMode) -> Void)?
    var shareMenu: ((UIView) -> UIMenu?)?
    var onShare: ((UIView) -> Void)?

    private let background = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let closeButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let modeControl = LunaSegmentedControl()
    private var modes: [ReadingListItem.ReaderMode] = []
    private var didInstallShare = false

    private static let controlSide: CGFloat = 34
    private static let height: CGFloat = 46
    private static let spacing: CGFloat = 6
    private static let inset: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.isUserInteractionEnabled = false
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        addSubview(background)

        configure(closeButton, symbol: "xmark", label: L10n.string("Close"))
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        configure(audioButton, symbol: "speaker.slash", label: L10n.string("Read Aloud"))
        audioButton.addAction(
            UIAction { [weak self] _ in self?.onToggleAudio?() }, for: .touchUpInside)
        configure(shareButton, symbol: "square.and.arrow.up", label: L10n.string("Share"))

        modeControl.addAction(
            UIAction { [weak self] _ in
                guard let self,
                      self.modes.indices.contains(self.modeControl.selectedSegmentIndex)
                else { return }
                self.onSelectMode?(self.modes[self.modeControl.selectedSegmentIndex])
            },
            for: .valueChanged)
        addSubview(modeControl)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configure(_ button: UIButton, symbol: String, label: String) {
        button.configuration = GlassStyle.circularButtonConfiguration(symbol: symbol, padding: 7)
        button.tintColor = GlassStyle.readingAccent
        button.accessibilityLabel = label
        addSubview(button)
    }

    func apply(_ state: ReaderChromeState?, providesShareMenu: Bool) {
        // Installed once and only once: `ShareButtonMenu.install` fixes the
        // menu-vs-tap behaviour at install time, and stacking a second install
        // would leave two handlers on one press.
        if !didInstallShare {
            didInstallShare = true
            ShareButtonMenu.install(
                on: shareButton,
                providesMenu: providesShareMenu,
                build: { [weak self] in
                    guard let self else { return nil }
                    return self.shareMenu?(self.shareButton)
                },
                fallback: { [weak self] in
                    guard let self else { return }
                    self.onShare?(self.shareButton)
                })
        }
        guard let state else {
            audioButton.isHidden = true
            shareButton.isHidden = true
            modeControl.isHidden = true
            setNeedsLayout()
            return
        }
        audioButton.isHidden = !state.isArticle
        audioButton.setImage(
            UIImage(systemName: state.isAudioOn ? "speaker.wave.2" : "speaker.slash"),
            for: .normal)
        audioButton.accessibilityValue =
            state.isAudioOn ? L10n.string("On") : L10n.string("Off")
        shareButton.isHidden = !state.offersSaveShare
        modeControl.isHidden = !state.isArticle
        if modes != state.modes {
            modes = state.modes
            modeControl.removeAllSegments()
            for (index, mode) in state.modes.enumerated() {
                modeControl.insertSegment(
                    with: ReaderModeIcons.image(for: mode), at: index, animated: false)
            }
        }
        modeControl.selectedSegmentIndex = state.modes.firstIndex(of: state.selectedMode) ?? 0
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let side = Self.controlSide
        var width = Self.inset * 2 + side   // close is always there
        if !modeControl.isHidden {
            width += Self.spacing + max(CGFloat(modes.count) * 40, 40)
        }
        for button in [audioButton, shareButton] where !button.isHidden {
            width += Self.spacing + side
        }
        return CGSize(width: min(width, max(size.width, side)), height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = bounds
        background.layer.cornerRadius = bounds.height / 2
        let side = Self.controlSide
        let y = (bounds.height - side) / 2
        var x = Self.inset
        closeButton.frame = CGRect(x: x, y: y, width: side, height: side)
        x = closeButton.frame.maxX

        // Trailing controls are placed from the right edge inward, so the mode
        // switcher takes whatever is left in the middle and the bar never has to
        // guess at the switcher's width.
        var trailing = bounds.width - Self.inset
        for button in [shareButton, audioButton] where !button.isHidden {
            button.frame = CGRect(x: trailing - side, y: y, width: side, height: side)
            trailing = button.frame.minX - Self.spacing
        }
        modeControl.frame = CGRect(
            x: x + Self.spacing, y: (bounds.height - 30) / 2,
            width: max(trailing - x - Self.spacing * 2, 0), height: 30)
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
        accessibilityLabel = L10n.string("Return to \(title)")
        backgroundColor = LunaColors.background
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
        titleLabelView.textColor = LunaColors.primaryText
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
        accessibilityLabel = L10n.string("Return to \(title)")
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
