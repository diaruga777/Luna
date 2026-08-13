//
//  LunaShareSheet.swift
//  LunaDesignSystem
//

import UIKit

/// Where a share sheet's iPad popover arrow anchors. The four cases match the
/// shapes hand-rolled call sites across the app already used: a view with no
/// explicit source rect (UIKit's own default), a view anchored by its full
/// bounds, a specific rect within a view (a text selection, a fixed point),
/// or a bar button item.
public enum LunaShareSheetAnchor {
    /// `sourceView` only — the source rect is left at UIKit's own default.
    case view(UIView)
    /// `sourceView` anchored by its own full bounds.
    case viewBounds(UIView)
    /// A specific rect within `view` (e.g. a text selection's frame).
    case rect(CGRect, in: UIView)
    case barButtonItem(UIBarButtonItem)
}

/// One place to build and present the system share sheet
/// (`UIActivityViewController`), so every call site gets correct iPad popover
/// anchoring — including a safe fallback when no anchor view is available —
/// without hand-rolling the same few lines and, occasionally, a force-unwrapped
/// anchor that could crash if the presenter's view weren't loaded yet.
public enum LunaShareSheet {
    /// Builds a `UIActivityViewController` for `items` and presents it from
    /// `presenter`, anchoring its popover per `anchor`.
    ///
    /// A `nil` anchor — meaning the caller had no specific view to point at —
    /// falls back to a centered point over `presenter`'s own view, the same
    /// fallback several hand-rolled call sites already computed by hand. A
    /// presenter whose view isn't loaded yet is a no-op rather than a crash.
    public static func present(
        items: [Any],
        from presenter: UIViewController,
        anchor: LunaShareSheetAnchor?,
        applicationActivities: [UIActivity]? = nil,
        completion: UIActivityViewController.CompletionWithItemsHandler? = nil
    ) {
        guard presenter.isViewLoaded else { return }
        let activity = UIActivityViewController(
            activityItems: items, applicationActivities: applicationActivities)
        if let completion {
            activity.completionWithItemsHandler = completion
        }
        if let popover = activity.popoverPresentationController {
            switch anchor {
            case .view(let view):
                popover.sourceView = view
            case .viewBounds(let view):
                popover.sourceView = view
                popover.sourceRect = view.bounds
            case .rect(let rect, let view):
                popover.sourceView = view
                popover.sourceRect = rect
            case .barButtonItem(let item):
                popover.barButtonItem = item
            case nil:
                let view: UIView = presenter.view
                popover.sourceView = view
                popover.sourceRect = CGRect(
                    x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            }
        }
        presenter.present(activity, animated: true)
    }
}
