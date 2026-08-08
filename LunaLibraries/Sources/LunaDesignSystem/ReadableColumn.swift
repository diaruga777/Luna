//
//  ReadableColumn.swift
//  LunaDesignSystem
//

import UIKit

/// The centred column a form-shaped screen lays its bands out in: as wide as the
/// container gives it, never wider than `LunaLayout.readableWidth`, and — the part
/// that is not negotiable — **never wider than the container itself**.
///
/// That last clause is why this exists rather than three hand-rolled copies. The
/// obvious spelling of "fill the width, but cap it" is a `.defaultHigh` `width ==
/// container.width` under a required `width <= readableWidth`, and it is wrong: a
/// high-priority constraint is one Auto Layout is allowed to BREAK, and the things
/// inside a column break it routinely. A `numberOfLines = 0` label reports its
/// single-line width as its intrinsic size on the first layout pass (UIKit only
/// learns the wrapping width from the frame it is given afterwards) and defends it
/// at 750 — the same priority as the preferred width. The tie went to the label:
/// the column grew to fit a whole sentence on one line, centred itself on a
/// container narrower than that, and hung the same distance off BOTH edges. The
/// price editor in the share sheet had every band clipped left and right that way,
/// and the media screen's floating Share circle rode off the right edge with it.
///
/// So the ceiling is stated as required inequalities against the safe area. The
/// preferred width still does the ordinary work; when content disagrees with it,
/// the content is the thing that has to give.
public enum ReadableColumn {

    /// Installs a horizontally centred column guide in `view`.
    ///
    /// - Parameters:
    ///   - view: the guide's owner; the column is centred in it and clamped to its
    ///     safe area.
    ///   - preferredWidthGuide: what the column matches when nothing objects —
    ///     the safe area by default, or e.g. `view.layoutMarginsGuide` for a
    ///     screen whose bands want the margins inset.
    ///   - maximumWidth: the readability cap.
    /// - Returns: the guide. The caller owns its vertical constraints.
    @MainActor
    @discardableResult
    public static func install(
        in view: UIView,
        preferring preferredWidthGuide: UILayoutGuide? = nil,
        maximumWidth: CGFloat = LunaLayout.readableWidth
    ) -> UILayoutGuide {
        let column = UILayoutGuide()
        install(column, in: view, preferring: preferredWidthGuide, maximumWidth: maximumWidth)
        return column
    }

    /// The same, for a host that already owns its guide.
    @MainActor
    public static func install(
        _ column: UILayoutGuide,
        in view: UIView,
        preferring preferredWidthGuide: UILayoutGuide? = nil,
        maximumWidth: CGFloat = LunaLayout.readableWidth
    ) {
        view.addLayoutGuide(column)
        let safeArea = view.safeAreaLayoutGuide
        let preferredWidth = column.widthAnchor.constraint(
            equalTo: (preferredWidthGuide ?? safeArea).widthAnchor)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth),
            // Required, and the whole point of this type: whatever the content
            // asks for, the container is the ceiling.
            column.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor),
            preferredWidth,
        ])
    }
}
