//
//  LoadingStatusLayout.swift
//  LunaDesignSystem
//

import UIKit

/// The ONE arrangement of a loading spinner and its status copy, shared by every
/// surface that waits on something: the action extension's first frame, the archive
/// reader's cover behind which a page is being unlocked.
///
/// It exists because those two run back to back in the same sheet, and any
/// difference between them reads as the UI jumping rather than as one wait
/// continuing. The SPINNER is centred, and the copy hangs beneath it, so the
/// spinner holds still at the same point on screen while text comes and goes
/// underneath.
///
/// The tint is deliberately NOT set: `HorizonSpinnerView` defaults to the horizon
/// palette (`MoonHorizonStyle.sunlight`). A surface that overrides it with the
/// reader accent — which follows the user's highlight preference and is usually
/// a bright blue — would make the spinner change colour at the handover.
public enum LoadingStatusLayout {

    /// Gap between the spinner and its status copy.
    public static let labelSpacing: CGFloat = 16
    /// Gap between the status copy and a trailing action (e.g. "Open in Safari").
    public static let actionSpacing: CGFloat = 20
    /// Side breathing room, so one line of copy never runs the full width of a wide
    /// extension sheet.
    public static let horizontalInset: CGFloat = 32

    /// Centres `spinner` in `container` with `label` beneath it, and optionally an
    /// `action` control beneath that. Applies the shared status-copy styling too, so
    /// font/colour can't drift between surfaces either.
    ///
    /// Every view is added to `container`; nothing is removed, so a caller keeps
    /// whatever else it has already installed.
    @MainActor
    public static func install(
        spinner: HorizonSpinnerView,
        label: EclipseBloomStatusLabel,
        action: UIView? = nil,
        in container: UIView
    ) {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = LunaColors.secondaryText
        label.font = .preferredFont(forTextStyle: .body)
        label.textAlignment = .center
        label.numberOfLines = 0

        container.addSubview(spinner)
        container.addSubview(label)

        var constraints: [NSLayoutConstraint] = [
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: labelSpacing),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor, constant: horizontalInset),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -horizontalInset),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: LunaLayout.readableWidth),
        ]
        if let action {
            action.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(action)
            constraints += [
                action.topAnchor.constraint(equalTo: label.bottomAnchor, constant: actionSpacing),
                action.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }
}
