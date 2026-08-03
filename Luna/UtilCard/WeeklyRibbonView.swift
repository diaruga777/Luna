//
//  WeeklyRibbonView.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// The corner flag a Save of the Week row wears.
///
/// The weekly noun used to ride inside the row, beside the host, where it cost
/// the host every character it spent (and truncated it). It is a RIBBON now: a
/// small pennant pinned to the row's TOP-LEFT corner, overlapping the artwork,
/// filled with the running app's own tint. The row clips to its rounded corners,
/// so the flag's outer corner is rounded by the row itself and this shape only
/// has to draw the swallowtail bitten out of its trailing edge.
final class WeeklyRibbonView: UIView {
    /// Tall enough for the 11pt caps and to overlap the top of a centred
    /// thumbnail by a few points — the overlap is what makes it read as pinned
    /// ON the artwork rather than as a band above it.
    static let height: CGFloat = 26
    /// The V bitten out of the trailing edge.
    private static let notch: CGFloat = 9
    /// Lines the text up with the thumbnail's own 11pt leading inset.
    private static let leadingInset: CGFloat = 12
    private static let trailingInset: CGFloat = 8
    private static let font = UIFont.systemFont(ofSize: 11, weight: .bold)

    private let shape = CAShapeLayer()
    private let label = UILabel()

    var text: String? {
        get { label.text }
        set {
            guard label.text != newValue else { return }
            label.text = newValue
            setNeedsLayout()
        }
    }

    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "utilCard.weeklyRibbon"
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        layer.addSublayer(shape)
        label.font = Self.font
        label.textColor = Self.textColor
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
        return Self.leadingInset + textWidth + Self.trailingInset + Self.notch
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.frame = bounds
        shape.path = Self.pennantPath(in: bounds).cgPath
        label.frame = CGRect(
            x: Self.leadingInset,
            y: 0,
            width: max(
                0,
                bounds.width - Self.leadingInset - Self.trailingInset - Self.notch),
            height: bounds.height)
    }

    /// Flush along the top and leading edges — the row's own corner radius does
    /// the rounding — with a V cut into the trailing edge.
    private static func pennantPath(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }

    private func applyTint() {
        shape.fillColor = LunaSurfacePalette.baseColor
            .resolvedColor(with: traitCollection).cgColor
        label.textColor = Self.textColor
    }

    /// The flag is a solid patch of the app's own colour, and the four colours
    /// straddle the legibility line: indigo and amber carry white, the Reader's
    /// periwinkle and the Price Tracker's green carry the row's own black.
    private static var textColor: UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard LunaSurfacePalette.baseColor.getRed(
            &red, green: &green, blue: &blue, alpha: &alpha)
        else { return .white }
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance > 0.6 ? UIColor(white: 0.04, alpha: 1) : .white
    }
}
