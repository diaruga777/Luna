//
//  NavHeaderTableController.swift
//  LunaDesignSystem
//
//  A `UITableViewController` base that replaces the UINavigationController nav bar with
//  an in-content `NavHeaderBar`.
//
//  Subclasses set `headerTitle` and optionally override `makeLeadingControls()` /
//  `makeTrailingControls()`. The default leading control is a back chevron that pops the
//  nav stack (or dismisses when presented as the root). The base hides the real nav bar
//  while visible, keeps the header pinned to the visible top, and maintains the table's
//  top content + scroll-indicator insets so rows clear the bar.
//
//  Subclasses keep all their normal `override func tableView(...)` data-source/delegate
//  methods unchanged.
//

import UIKit

open class NavHeaderTableController: UITableViewController {

    /// The bar title. Set before `viewDidLoad` (or any time — it updates live).
    public var headerTitle: String? {
        didSet { header.title = headerTitle }
    }

    /// The recreated header bar. Exposed so subclasses with custom needs can reach it.
    public let header = NavHeaderBar()

    /// Keeps left-edge swipe-back alive while the real nav bar is hidden.
    private let popGestureClaim = InteractivePopGestureClaim()

    open override func viewDidLoad() {
        super.viewDidLoad()
        header.title = headerTitle
        header.setLeadingControls(makeLeadingControls())
        header.setTrailingControls(makeTrailingControls())
        header.mount(in: self)
        updateHeaderMetrics()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Take over the header from the (now hidden) shared nav bar.
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    /// Hiding the nav bar takes UIKit's left-edge pop gesture with it, so a pushed
    /// screen would otherwise only be dismissable by the back chevron.
    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        popGestureClaim.claim(in: navigationController)
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        popGestureClaim.release()
    }

    open override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateHeaderMetrics()
    }

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeaderMetrics()
        // The header is a subview of the scrolling table, and the table appends
        // cell views as they come into view. `zPosition` fixes DRAW order but not
        // hit-testing (which walks subviews back-to-front), so a scrolled-in cell
        // overlapping the bar would swallow taps on the back button. Keeping the
        // header last in the subview array keeps its controls tappable at any
        // scroll offset.
        if let tableView, tableView.subviews.last !== header {
            tableView.bringSubviewToFront(header)
        }
    }

    /// Keeps the header height (= safe-area top + bar) and the table's top insets in sync
    /// with the live safe area, so rows always start just below the bar.
    private func updateHeaderMetrics() {
        let top = view.safeAreaInsets.top
        header.setManagedHeight(topSafeAreaInset: top)
        // `.automatic` content-inset adjustment already accounts for the safe-area top;
        // add only the bar row's own height so rows clear it.
        if abs(tableView.contentInset.top - NavHeaderBar.barHeight) > 0.5 {
            tableView.contentInset.top = NavHeaderBar.barHeight
            tableView.verticalScrollIndicatorInsets.top = NavHeaderBar.barHeight
        }
    }

    open override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        header.updateScrolledAppearance(
            contentOffsetY: scrollView.contentOffset.y,
            adjustedTopInset: scrollView.adjustedContentInset.top)
    }

    // MARK: - Subclass hooks

    /// The leading controls. Default: a back chevron that pops/dismisses. Override to
    /// supply custom leading controls (return `[]` for none).
    open func makeLeadingControls() -> [UIView] {
        [NavHeaderBar.backButton(target: self, action: #selector(navHeaderBack))]
    }

    /// The trailing controls. Default: none. Override to supply right-side controls.
    open func makeTrailingControls() -> [UIView] { [] }

    @objc open func navHeaderBack() {
        if let navigationController, navigationController.viewControllers.count > 1 {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }
}
