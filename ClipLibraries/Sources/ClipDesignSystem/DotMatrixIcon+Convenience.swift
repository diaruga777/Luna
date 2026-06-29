//
//  DotMatrixIcon+Convenience.swift
//  ClipDesignSystem
//
//  Ergonomic helpers for vending dot-matrix glyphs into the common UIKit chrome:
//  `UIImage`, `UIBarButtonItem`, and `UIButton`. These keep the existing tap targets,
//  sizes, and target/action wiring intact — only the glyph artwork changes.
//

import UIKit

extension UIImage {
    /// A dot-matrix template image for an SF Symbol. Drop-in for
    /// `UIImage(systemName:)` in nav-bar / toolbar / button slots. Returns a plain
    /// `UIImage(systemName:)` fallback if dot rendering fails.
    public static func dotMatrixIcon(
        systemName: String,
        pointSize: CGFloat = 17,
        weight: UIImage.SymbolWeight = .semibold,
        style: DotMatrixIconStyle = .standard
    ) -> UIImage? {
        DotMatrixIcon.image(systemName: systemName, pointSize: pointSize, weight: weight, style: style)
            ?? UIImage(systemName: systemName)
    }
}

extension UIBarButtonItem {
    /// A bar button item whose glyph is rendered in the dot-matrix style.
    public convenience init(
        dotMatrixSystemName systemName: String,
        pointSize: CGFloat = 18,
        weight: UIImage.SymbolWeight = .semibold,
        target: AnyObject?,
        action: Selector?
    ) {
        let image = UIImage.dotMatrixIcon(systemName: systemName, pointSize: pointSize, weight: weight)
        self.init(image: image, style: .plain, target: target, action: action)
    }
}

extension UIButton {
    /// Set a dot-matrix-rendered glyph on a configuration-based button, preserving
    /// everything else about the existing configuration. No-op (falls back to a plain
    /// symbol) if rendering fails.
    public func setDotMatrixImage(
        systemName: String,
        pointSize: CGFloat = 17,
        weight: UIImage.SymbolWeight = .semibold,
        for state: UIControl.State = .normal
    ) {
        let image = UIImage.dotMatrixIcon(systemName: systemName, pointSize: pointSize, weight: weight)
        if configuration != nil {
            configuration?.image = image
        } else {
            setImage(image, for: state)
        }
    }
}
