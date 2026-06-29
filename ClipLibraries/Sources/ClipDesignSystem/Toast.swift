//
//  Toast.swift
//  Clip
//

import UIKit

/// A brief, non-blocking confirmation shown as a wide, short liquid-glass pill
/// at the bottom of the screen (replaces center-of-screen confirmation alerts).
/// Auto-dismisses; tap to dismiss early.
public enum Toast {

    /// Optional appearance animator for the pill, injected from a higher layer so the
    /// toast can use the Dot Matrix pixelate-in without `ClipDesignSystem` depending on
    /// `ClipTransitions` (which would be a dependency cycle — `ClipTransitions` already
    /// depends on `ClipDesignSystem`). Installed once at launch; nil ⇒ the built-in
    /// spring slide-up. The pill is already added to its host and laid out at its final
    /// frame when this is called.
    @MainActor public static var appearanceAnimator: ((UIView) -> Void)?

    /// Shows `message` (with an optional leading SF Symbol) over `presenter`'s
    /// window, sliding up from the bottom and fading out after a moment.
    @MainActor
    public static func show(_ message: String, symbol: String? = "checkmark.circle.fill",
                     from presenter: UIViewController) {
        guard let host = presenter.view.window ?? presenter.view else { return }

        let pill = UIVisualEffectView(effect: GlassStyle.barEffect())
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.clipsToBounds = true
        if #available(iOS 26.0, *) {
            (pill as UIVisualEffectView).cornerConfiguration = .capsule()
        } else {
            pill.layer.cornerRadius = 26
        }

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
        pill.contentView.addSubview(stack)
        host.addSubview(pill)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 24),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -24),
            pill.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            pill.heightAnchor.constraint(equalToConstant: 52),
            stack.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: pill.contentView.centerYAnchor),
        ])

        pill.addGestureRecognizer(UITapGestureRecognizer(
            target: pill, action: #selector(UIView.dismissToast)))

        // Lay the pill out at its final frame so the appearance animator can snapshot it.
        host.layoutIfNeeded()

        if let appearanceAnimator {
            // Dot Matrix pixelate-in (injected at launch): the pill assembles dot-by-dot.
            pill.transform = .identity
            appearanceAnimator(pill)
        } else {
            // Built-in fallback: spring slide-up from the bottom.
            pill.alpha = 0
            pill.transform = CGAffineTransform(translationX: 0, y: 30)
            UIView.animate(withDuration: 0.3, delay: 0,
                           usingSpringWithDamping: 0.8, initialSpringVelocity: 0.4) {
                pill.alpha = 1
                pill.transform = .identity
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak pill] in
            pill?.dismissToast()
        }
    }
}

private extension UIView {
    @objc func dismissToast() {
        UIView.animate(withDuration: 0.25, animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: 20)
        }, completion: { _ in self.removeFromSuperview() })
    }
}
