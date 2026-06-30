//
//  NavHeaderHosting.swift
//  LuneDesignSystem
//
//  Helpers to mount a `NavHeaderBar` into a screen in place of the UINavigationController
//  nav bar, so the header travels with the content during the Dot Matrix transition.
//
//  Two host shapes:
//  - A `UITableViewController` whose `view` IS the table: the header is added as a
//    subview pinned to the scroll view's FRAME layout guide (the visible frame, not the
//    scrolling content), and the table's content/indicator insets are grown so rows
//    start below it. Because it's a subview of the snapshotted `toView`, it's captured
//    in the wipe; because it's pinned to the frame guide, it doesn't scroll.
//  - A plain `UIViewController`: the header is pinned to the view's safe-area top, and
//    the caller lays its content out below `header.bottomAnchor`.
//

import UIKit

public extension NavHeaderBar {

    /// Mounts this header into a `UITableViewController`, pinned to the visible top of
    /// the table (it does not scroll), spanning the safe-area top inset plus the bar
    /// row, and grows the table's top content + scroll-indicator insets to match so the
    /// first rows aren't hidden underneath. Returns nothing — the header keeps itself
    /// pinned via Auto Layout against the scroll view's frame layout guide.
    ///
    /// Call once from `viewDidLoad`. The host should also forward scrolling to
    /// `updateScrolledAppearance` (see `NavHeaderScrollTracking`) and hide the real nav
    /// bar (`hostHidesNavigationBar`).
    func mount(in tableController: UITableViewController) {
        let tableView = tableController.tableView!
        tableView.addSubview(self)
        // Pin to the FRAME layout guide so the header stays fixed at the visible top
        // while content scrolls beneath it (the content layout guide would scroll it).
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: tableView.frameLayoutGuide.topAnchor),
            leadingAnchor.constraint(equalTo: tableView.frameLayoutGuide.leadingAnchor),
            trailingAnchor.constraint(equalTo: tableView.frameLayoutGuide.trailingAnchor),
        ])
        // The header always floats above the rows it overlaps.
        tableView.layer.zPosition = 0
        layer.zPosition = 1
    }

    /// The header's total height for a given top safe-area inset (used to set content
    /// insets). The header spans the safe-area top plus the 44pt bar row.
    static func totalHeight(topSafeAreaInset: CGFloat) -> CGFloat {
        topSafeAreaInset + barHeight
    }

    /// Mounts this header into a plain `UIViewController`, pinned to the top edge of its
    /// `view` and spanning down to the bar row (its bottom anchor — which the caller pins
    /// the screen's content below). The header's height is `safe-area top + bar row`.
    /// Returns the header's bottom anchor so the caller can lay content out beneath it.
    @discardableResult
    func mount(in viewController: UIViewController) -> NSLayoutYAxisAnchor {
        let host = viewController.view!
        host.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: Self.barHeight),
        ])
        return bottomAnchor
    }
}
