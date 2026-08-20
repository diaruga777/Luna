//
//  WeeklyRibbonView.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// The corner flag a Luna team row wears.
///
/// A small tab pinned to the row's top-left corner, filled with the running
/// app's own tint dimmed into the row's black. The row clips to its rounded
/// corners, so the flag's outer corner is rounded by the row itself and this
/// shape only has to draw the sweep of its trailing edge.
final class WeeklyRibbonView: UIView {
    /// Short enough to clear the top of a centred thumbnail — the flag sits
    /// ABOVE the artwork, never across it — and no taller than the 10pt caps
    /// plus their margins need.
    static let height: CGFloat = 20
    /// How far the trailing edge's arc runs horizontally. It leaves the bottom
    /// edge tangentially and rises to meet the top edge, so the flag ends in one
    /// smooth sweep rather than a swallowtail's two straight cuts.
    private static let arcSweep: CGFloat = 13
    /// Lines the text up with the thumbnail's own 11pt leading inset.
    private static let leadingInset: CGFloat = 11
    private static let trailingInset: CGFloat = 5
    private static let font = UIFont.systemFont(ofSize: 10, weight: .bold)
    /// How much of the app's colour survives the dim toward the row's black.
    /// Enough that each app still flies its own flag, little enough that a patch
    /// of neon green or periwinkle no longer outshines the pick it labels.
    private static let tintStrength: CGFloat = 0.45

    private let shape = CAShapeLayer()
    private let label = UILabel()
    private var tint = LunaSurfacePalette.baseColor

    var text: String? {
        get { label.text }
        set {
            guard label.text != newValue else { return }
            label.text = newValue
            setNeedsLayout()
        }
    }

    func setTint(_ tint: UIColor) {
        self.tint = tint
        applyTint()
    }

    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "utilCard.weeklyRibbon"
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        layer.addSublayer(shape)
        label.font = Self.font
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isAccessibilityElement = false
        addSubview(label)
        applyTint()
        // A shape layer holds a RESOLVED CGColor, and a style change never
        // arrives again under the pinned-dark trait — only the sky trait does.
        registerForTraitChanges([LunaSkyTrait.self]) {
            (ribbon: WeeklyRibbonView, _: UITraitCollection) in
            ribbon.applyTint()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The width this flag wants for the text it currently carries — the caller
    /// caps it against the row, since a long localisation must not sail across
    /// the whole card.
    var fittingWidth: CGFloat {
        let text = label.text ?? ""
        guard !text.isEmpty else { return 0 }
        let textWidth = (text as NSString).size(
            withAttributes: [.font: Self.font]).width.rounded(.up)
        return Self.leadingInset + textWidth + Self.trailingInset + Self.arcClearance
    }

    /// How much of the arc's run the text must stay clear of. The sweep only
    /// bites into the flag as it descends, so the letters — which sit on the
    /// middle line — need less room than its full horizontal run.
    private static var arcClearance: CGFloat { (arcSweep * 0.55).rounded() }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.frame = bounds
        shape.path = Self.pennantPath(in: bounds).cgPath
        label.frame = CGRect(
            x: Self.leadingInset,
            y: 0,
            width: max(
                0,
                bounds.width - Self.leadingInset - Self.trailingInset - Self.arcClearance),
            height: bounds.height)
    }

    /// Flush along the top and leading edges — the row's own corner radius does
    /// the rounding — and closed by a single arc on the trailing edge: it leaves
    /// the bottom edge horizontally and turns up to meet the top edge vertically,
    /// so there is no corner anywhere along the sweep.
    static func pennantPath(in rect: CGRect) -> UIBezierPath {
        let sweep = min(arcSweep, rect.width)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Vertical where it meets the top edge, horizontal where it rejoins the
        // bottom one — the two tangents are what keep it reading as one arc.
        path.addCurve(
            to: CGPoint(x: rect.maxX - sweep, y: rect.maxY),
            controlPoint1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.55),
            controlPoint2: CGPoint(x: rect.maxX - sweep * 0.45, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }

    private func applyTint() {
        shape.fillColor = Self.fillColor(for: tint).resolvedColor(with: traitCollection).cgColor
        label.textColor = Self.textColor
    }

    /// The app's own colour pulled most of the way into the row's black. At full
    /// strength the four palettes were a bright patch competing with the
    /// artwork; dimmed, the flag reads as part of the row it labels.
    static var fillColor: UIColor { fillColor(for: LunaSurfacePalette.currentSurface) }

    static func fillColor(for surface: LunaSurfacePalette.Surface) -> UIColor {
        fillColor(for: LunaSurfacePalette.baseColor(for: surface))
    }

    static func fillColor(for tint: UIColor) -> UIColor {
        LunaSurfacePalette.blended(
            tint,
            toward: UtilURLRow.rowBackground,
            amount: 1 - tintStrength)
    }

    /// Dimmed, every one of the four fills sits far enough below the letters
    /// to carry white text without a per-app exception.
    static let textColor = UIColor(white: 0.97, alpha: 1)
}
