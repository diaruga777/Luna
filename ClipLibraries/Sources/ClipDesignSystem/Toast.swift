//
//  Toast.swift
//  Clip
//

import UIKit

/// A brief, non-blocking confirmation shown as a wide, short pill at the bottom of the
/// screen (replaces center-of-screen confirmation alerts). It appears with a Dot Matrix
/// pixelate-in and disappears with a matching pixelate-out — a dissolve in place, no
/// slide. Auto-dismisses; tap to dismiss early.
public enum Toast {

    /// Optional appearance animator for the pill, injected from a higher layer so the
    /// toast can use the Dot Matrix pixelate-in without `ClipDesignSystem` depending on
    /// `ClipTransitions` (which would be a dependency cycle — `ClipTransitions` already
    /// depends on `ClipDesignSystem`). Installed once at launch; nil ⇒ the built-in
    /// fade-in. The pill is already added to its host and laid out at its final frame
    /// when this is called.
    @MainActor public static var appearanceAnimator: ((UIView) -> Void)?

    /// Optional disappearance animator, the mirror of `appearanceAnimator`. Injected from
    /// a higher layer so the pill dissolves OUT in place with the same Dot Matrix wipe it
    /// appeared with. It is responsible for removing the pill from its superview when the
    /// animation lands (the injected `DotMatrixDisappear.pixelateOut` does this, and so
    /// does the built-in fallback below). nil ⇒ the built-in fade-out + removal.
    @MainActor public static var disappearanceAnimator: ((UIView) -> Void)?

    /// Shows `message` (with an optional leading SF Symbol) over `presenter`'s window. The
    /// pill assembles in place with a Dot Matrix pixelate-in and, after a moment, dissolves
    /// back out in place with the matching pixelate-out — no slide either way.
    @MainActor
    public static func show(_ message: String, symbol: String? = "checkmark.circle.fill",
                     from presenter: UIViewController) {
        guard let host = presenter.view.window ?? presenter.view else { return }

        // A plain solid pill (not a live glass/blur material): a `UIVisualEffectView`
        // can't be snapshotted faithfully for the Dot Matrix wipe (the engine reads it as
        // a muddy/semi-transparent backdrop, so the pixels emerge flickery and dim). The
        // solid bar fill reads like the material it replaces in both light and dark mode
        // and composites cleanly cell-by-cell.
        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = GlassStyle.solidBarColor
        pill.clipsToBounds = true
        pill.layer.cornerRadius = 26
        pill.layer.cornerCurve = .continuous

        var arranged: [UIView] = []
        if let symbol, let image = UIImage(systemName: symbol) {
            let icon = UIImageView(image: image)
            icon.tintColor = GlassStyle.readingAccent
            icon.setContentHuggingPriority(.required, for: .horizontal)
            arranged.append(icon)
        }
        let label = UILabel()
        label.text = message
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .label
        label.numberOfLines = 1
        arranged.append(label)

        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)
        host.addSubview(pill)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 24),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -24),
            pill.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            pill.heightAnchor.constraint(equalToConstant: 52),
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])

        pill.addGestureRecognizer(UITapGestureRecognizer(
            target: pill, action: #selector(UIView.dismissToast)))

        // Lay the pill out at its final frame so the appearance animator can snapshot it.
        host.layoutIfNeeded()

        if let appearanceAnimator {
            // Dot Matrix pixelate-in (injected at launch): the pill assembles dot-by-dot.
            // No transform — the wipe reveals it in place.
            pill.transform = .identity
            appearanceAnimator(pill)
        } else {
            // Built-in fallback: a clean fade-in (no slide).
            pill.alpha = 0
            UIView.animate(withDuration: 0.3) { pill.alpha = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak pill] in
            pill?.dismissToast()
        }
    }
}

private extension UIView {
    @objc func dismissToast() {
        // Guard against a double dismiss (auto-timer firing after a tap, or vice versa):
        // once detached from its superview, or already mid-dismiss, do nothing.
        guard superview != nil, !isToastDismissing else { return }
        isToastDismissing = true

        if let animator = Toast.disappearanceAnimator {
            // Dot Matrix pixelate-out (injected at launch): the pill dissolves OUT in
            // place, mirroring the appearance. The animator removes the pill on landing.
            animator(self)
        } else {
            // Built-in fallback: a clean fade-out in place (no slide), then removal.
            UIView.animate(withDuration: 0.25, animations: { self.alpha = 0 },
                           completion: { _ in self.removeFromSuperview() })
        }
    }

    private static var dismissingKey: UInt8 = 0
    var isToastDismissing: Bool {
        get { objc_getAssociatedObject(self, &Self.dismissingKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &Self.dismissingKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
