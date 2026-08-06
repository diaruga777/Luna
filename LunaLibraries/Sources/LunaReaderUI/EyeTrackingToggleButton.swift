//
//  EyeTrackingToggleButton.swift
//  LunaReaderUI
//

import LunaDesignSystem
import LunaModels
import UIKit

/// The RSVP reader's eye-tracking toggle: the same Liquid Glass circle as the
/// reader chrome's read-aloud button, showing one of four states.
///
/// - `.disabled` — a closed eyelid, grey.
/// - `.enabled` — an open eye, grey.
/// - `.active` — the same open eye in the reading accent, while it is actually
///   watching a running playback.
/// - `.unavailable` — a red slashed eye while the enabled tracker has lost the
///   reader's eyes; it deliberately has no effect until a signal returns.
public final class EyeTrackingToggleButton: UIButton {

    public static let diameter: CGFloat = 38
    private static let glyphPointSize: CGFloat = 17

    public var trackingState: EyeTrackingDisplayState = .disabled {
        didSet {
            guard trackingState != oldValue else { return }
            applyState()
        }
    }

    public init() {
        super.init(frame: .zero)
        configuration = GlassStyle.circularButtonConfiguration(symbol: "eye.fill", padding: 8)
        clipsToBounds = true
        layer.cornerRadius = Self.diameter / 2
        layer.cornerCurve = .circular
        applyState()
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    /// Resolved accent colours are cached in the configuration, and the chosen
    /// appearance rides `LunaSkyTrait` rather than `userInterfaceStyle` — a
    /// style change will never arrive, so re-resolve on the sky trait.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        registerForTraitChanges([LunaSkyTrait.self]) { (button: EyeTrackingToggleButton, _) in
            button.applyState()
        }
    }

    private func applyState() {
        var updated = configuration ?? GlassStyle.circularButtonConfiguration(symbol: "eye.fill", padding: 8)
        updated.image = Self.glyph(for: trackingState)
        let tint: UIColor
        switch trackingState {
        case .active:
            // Assign the configuration back as a value. Mutating through an
            // optional configuration leaves a glass button's foreground at
            // UIKit's default white on some OS releases.
            tint = GlassStyle.readingAccent
        case .unavailable:
            tint = LunaColors.errorAccent
        case .disabled, .enabled:
            tint = LunaColors.secondaryText
        }
        updated.baseForegroundColor = tint
        configuration = updated
        tintColor = tint
        accessibilityLabel = Self.accessibilityLabel(for: trackingState)
        accessibilityValue = Self.accessibilityValue(for: trackingState)
    }

    private static func glyph(for state: EyeTrackingDisplayState) -> UIImage? {
        switch state {
        case .disabled:
            return ClosedEyelidGlyph.image(pointSize: glyphPointSize)
        case .enabled, .active:
            return UIImage(
                systemName: "eye.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: glyphPointSize))
        case .unavailable:
            return UIImage(
                systemName: "eye.slash.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: glyphPointSize))
        }
    }

    private static func accessibilityLabel(for state: EyeTrackingDisplayState) -> String {
        state == .disabled
            ? L10n.string("Reader_rsvp_eyeTracking_turnOnAccessibilityLabel")
            : L10n.string("Reader_rsvp_eyeTracking_turnOffAccessibilityLabel")
    }

    private static func accessibilityValue(for state: EyeTrackingDisplayState) -> String {
        switch state {
        case .disabled: return L10n.string("Reader_rsvp_eyeTracking_offAccessibilityValue")
        case .enabled: return L10n.string("Reader_rsvp_eyeTracking_watchingAccessibilityValue")
        case .active: return L10n.string("Reader_rsvp_eyeTracking_pausingAccessibilityValue")
        case .unavailable: return L10n.string("Reader_rsvp_eyeTracking_unavailableAccessibilityValue")
        }
    }
}

/// A closed eye, drawn rather than named: SF Symbols ships `eye`, `eye.fill`
/// and `eye.slash`, but no closed lid, and a slashed eye reads as "hidden
/// content" — the wrong idea for a tracker that is simply switched off. The
/// proportions follow `eye.fill`'s almond so the two states swap without the
/// glyph appearing to change size.
enum ClosedEyelidGlyph {

    static func image(pointSize: CGFloat) -> UIImage {
        let width = (pointSize * 1.36).rounded()
        let height = pointSize.rounded()
        let size = CGSize(width: width, height: height)
        let lineWidth = max(1.5, (pointSize * 0.115).rounded(.toNearestOrEven))

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            cgContext.setLineWidth(lineWidth)
            cgContext.setLineCap(.round)
            cgContext.setStrokeColor(UIColor.black.cgColor)

            // The lid: the lower arc of the open eye's almond, so the closed
            // state sits on the same baseline the open eye's pupil does.
            let inset = lineWidth / 2 + 0.5
            let left = CGPoint(x: inset, y: height * 0.42)
            let right = CGPoint(x: width - inset, y: height * 0.42)
            let lidDepth = height * 0.30
            let lid = UIBezierPath()
            lid.move(to: left)
            lid.addQuadCurve(
                to: right,
                controlPoint: CGPoint(x: width / 2, y: left.y + lidDepth * 2))
            cgContext.addPath(lid.cgPath)
            cgContext.strokePath()

            // Three lashes below the lid, splayed outward from its low point.
            let lashLength = height * 0.22
            for (fraction, angle) in [(0.24, -0.55), (0.5, 0.0), (0.76, 0.55)] as [(CGFloat, CGFloat)] {
                let anchor = lid.point(atFraction: fraction, from: left, to: right, depth: lidDepth)
                let end = CGPoint(
                    x: anchor.x + sin(angle) * lashLength,
                    y: anchor.y + cos(angle) * lashLength)
                cgContext.move(to: anchor)
                cgContext.addLine(to: end)
            }
            cgContext.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

private extension UIBezierPath {
    /// The point on the lid's quadratic curve at `fraction` of its span —
    /// evaluated directly rather than flattened, so the lashes meet the stroke
    /// exactly.
    func point(
        atFraction fraction: CGFloat, from start: CGPoint, to end: CGPoint, depth: CGFloat
    ) -> CGPoint {
        let control = CGPoint(x: (start.x + end.x) / 2, y: start.y + depth * 2)
        let inverse = 1 - fraction
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * fraction * control.x
                + fraction * fraction * end.x,
            y: inverse * inverse * start.y + 2 * inverse * fraction * control.y
                + fraction * fraction * end.y)
    }
}
