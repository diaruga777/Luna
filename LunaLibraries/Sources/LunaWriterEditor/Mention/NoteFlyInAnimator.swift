//
//  NoteFlyInAnimator.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem

/// Sends a small note glyph from the "@" to the notes button, so a capture
/// shows where it went.
public enum NoteFlyInAnimator {

    public static let duration: TimeInterval = 0.45

    public static func fly(from origin: CGRect, to destination: CGPoint, in container: UIView) {
        let glyph = UIImageView(image: UIImage(systemName: "note.text"))
        glyph.tintColor = EditorTheme.caret
        glyph.contentMode = .scaleAspectFit
        glyph.frame = CGRect(x: origin.midX - 11, y: origin.midY - 11, width: 22, height: 22)
        glyph.alpha = 0
        container.addSubview(glyph)

        UIView.animate(withDuration: duration * 0.25) {
            glyph.alpha = 1
        }
        UIView.animate(
            withDuration: duration, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.2,
            options: [.curveEaseInOut]
        ) {
            glyph.center = destination
            glyph.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            glyph.alpha = 0
        } completion: { _ in
            glyph.removeFromSuperview()
        }
    }
}
