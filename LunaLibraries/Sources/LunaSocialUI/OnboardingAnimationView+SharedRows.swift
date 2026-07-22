//
//  OnboardingAnimationView+SharedRows.swift
//  Luna
//

import LunaDesignSystem
import UIKit

extension OnboardingAnimationView {

    // MARK: - Shared sheet-chrome helpers

    /// Styles an (already-instantiated) view as a rounded, top-cornered card
    /// matching the system share-sheet / menu chrome used by several of the
    /// illustrations below.
    func configureSheetShell(_ v: UIView, cornerRadius: CGFloat = 18) {
        v.backgroundColor = LunaColors.background
        v.layer.cornerRadius = cornerRadius
        v.layer.cornerCurve = .continuous
        v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        v.layer.borderColor = LunaColors.separator.cgColor
        v.layer.borderWidth = 0.5
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The small horizontal grabber at the top of a sheet.
    func sheetGrabber() -> UIView {
        let g = UIView()
        g.backgroundColor = .systemGray3
        g.layer.cornerRadius = 2.5
        g.translatesAutoresizingMaskIntoConstraints = false
        return g
    }

    /// A literal (non-placeholder) share-sheet-style row: an SF Symbol leading
    /// icon and a real text label, used for the handful of rows the new
    /// illustrations call out by name (e.g. "Manage Extensions").
    func literalActionRow(symbol: String, text: String, tint: UIColor = LunaColors.primaryText) -> UIView {
        let icon = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12)))
        icon.tintColor = tint
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = tint
        return axActionRow(icon: icon, trailing: label)
    }

    /// A small on/off toggle track+thumb pair, styled like `buildToggle`'s but
    /// sized for use inside a compact row (rather than a full Settings row).
    func miniToggle() -> (track: UIView, thumb: UIView) {
        let track = UIView()
        track.backgroundColor = .systemGray3
        track.layer.cornerRadius = 9
        track.translatesAutoresizingMaskIntoConstraints = false
        track.widthAnchor.constraint(equalToConstant: 32).isActive = true
        track.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let thumb = UIView()
        thumb.backgroundColor = .white
        thumb.layer.cornerRadius = 7
        thumb.layer.shadowColor = UIColor.black.cgColor
        thumb.layer.shadowOpacity = 0.2
        thumb.layer.shadowRadius = 1.5
        thumb.layer.shadowOffset = CGSize(width: 0, height: 1)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(thumb)
        thumb.frame = CGRect(x: 2, y: 2, width: 14, height: 14)
        return (track, thumb)
    }

    /// A rounded gray "text line" bar, width as a fraction of its container.
    func bar(width: CGFloat, height: CGFloat, color: UIColor = .systemGray3) -> UIView {
        let v = UIView()
        v.backgroundColor = color
        v.layer.cornerRadius = height / 2
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        let parent = UIView()
        parent.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            v.widthAnchor.constraint(equalTo: parent.widthAnchor, multiplier: width),
            parent.heightAnchor.constraint(equalToConstant: height),
        ])
        return parent
    }

    /// A grey Safari-toolbar icon (back/forward/book/tabs).
    func toolbarIcon(_ symbol: String) -> UIImageView {
        let icon = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)))
        icon.tintColor = LunaColors.secondaryText
        icon.contentMode = .center
        return icon
    }

    /// A small grey app-icon circle for the share sheet's top row.
    func axAppIcon() -> UIView {
        let icon = UIView()
        icon.backgroundColor = .systemGray4
        icon.layer.cornerRadius = 11
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return icon
    }

    /// A generic share-sheet action row: a leading SF icon and a trailing grey
    /// text-placeholder bar, ~28pt tall (no literal text). `placeholderWidth`
    /// varies per row so the list reads like distinct actions.
    func axActionRow(symbol: String, placeholderWidth: CGFloat) -> UIView {
        let icon = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12)))
        icon.tintColor = LunaColors.primaryText
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let labelPlaceholder = UIView()
        labelPlaceholder.backgroundColor = LunaColors.primaryText.withAlphaComponent(0.35)
        labelPlaceholder.layer.cornerRadius = 3
        labelPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        labelPlaceholder.widthAnchor.constraint(equalToConstant: placeholderWidth).isActive = true
        labelPlaceholder.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return axActionRow(icon: icon, trailing: labelPlaceholder)
    }

    /// Lays out one share-sheet action row: leading icon, flexible gap, trailing
    /// text element (grey bar or real label), 28pt tall.
    func axActionRow(icon: UIView, trailing: UIView) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let stack = UIStackView(arrangedSubviews: [icon, UIView(), trailing])
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

}
