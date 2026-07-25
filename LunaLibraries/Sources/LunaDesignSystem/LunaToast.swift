//
//  LunaToast.swift
//  LunaDesignSystem
//

import UIKit

/// A brief, non-modal confirmation that rises near the bottom of the screen and
/// fades out on its own.
///
/// It exists to replace the modal `UIAlertController` flash the copy actions used
/// to show. A modal takes over the screen and — worse — cannot be presented while
/// a menu or sheet is still dismissing, so its confirmation always arrived a beat
/// after the tap. A toast is a plain non-interactive subview of the window, so it
/// can appear the same runloop turn as the action that triggered it.
public enum LunaToast {

    /// Height of the capsule; also its corner radius (a pill).
    private static let height: CGFloat = 42
    /// Distance from the safe-area bottom the capsule settles at.
    private static let bottomInset: CGFloat = 34
    private static let tag = 0x10_5A_57  // "LuToast"

    /// Shows `text` over the window holding `presenter`'s view, falling back to
    /// the view itself when it isn't in a window yet.
    public static func show(
        _ text: String, from presenter: UIViewController, duration: TimeInterval = 1.3
    ) {
        let host = presenter.viewIfLoaded?.window ?? presenter.view
        guard let host else { return }
        show(text, in: host, duration: duration)
    }

    /// Shows `text` inside `host`, replacing any toast already there so a burst of
    /// taps doesn't stack capsules on top of each other.
    public static func show(_ text: String, in host: UIView, duration: TimeInterval = 1.3) {
        host.viewWithTag(tag)?.removeFromSuperview()

        let capsule = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        capsule.tag = tag
        capsule.isUserInteractionEnabled = false
        capsule.layer.cornerRadius = height / 2
        capsule.layer.cornerCurve = .continuous
        capsule.clipsToBounds = true
        capsule.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = LunaColors.primaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(label)

        host.addSubview(capsule)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: capsule.contentView.centerYAnchor),
            capsule.heightAnchor.constraint(equalToConstant: height),
            capsule.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            capsule.bottomAnchor.constraint(
                equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -bottomInset),
        ])

        capsule.alpha = 0
        capsule.transform = CGAffineTransform(translationX: 0, y: 14)
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            capsule.alpha = 1
            capsule.transform = .identity
        }
        UIView.animate(withDuration: 0.28, delay: duration, options: [.curveEaseIn]) {
            capsule.alpha = 0
            capsule.transform = CGAffineTransform(translationX: 0, y: 10)
        } completion: { _ in
            capsule.removeFromSuperview()
        }
    }
}
