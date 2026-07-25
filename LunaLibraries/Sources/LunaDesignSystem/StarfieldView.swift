//
//  StarfieldView.swift
//  LunaDesignSystem
//

import UIKit

/// The night sky behind the cards: a fixed, extremely faint scatter of stars.
///
/// Deliberately below the threshold of casual notice — the brightest star sits
/// at roughly 13% alpha and most sit under 6%, so the background still reads as
/// black and only rewards someone who looks. Nothing animates; a twinkle would
/// announce the effect and defeat the point.
///
/// The sky is *fixed*: positions come from one deterministic table generated at
/// load, in normalised coordinates, so every screen and every app shows the same
/// constellations and a rotation or resize never reshuffles them. Stars carry the
/// current app's `LunaSurfacePalette.atmosphereTint`, mostly washed out toward
/// white — the central Luna app's tint is already white, so its sky is plain
/// moonlight.
public final class StarfieldView: UIView {

    /// One star in normalised (0…1) sky coordinates.
    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
        let alpha: CGFloat
        /// A handful of stars get a soft bloom, the way a brighter star spreads
        /// slightly in a long exposure.
        let bloom: Bool
    }

    /// Roughly one star per 2,000 pt² on a phone — sparse enough that the eye
    /// reads texture rather than pattern.
    private static let starCount = 170

    private static let sky: [Star] = makeSky()

    private static func makeSky() -> [Star] {
        // A fixed-seed LCG (Numerical Recipes constants) keeps the sky identical
        // across launches, devices, and processes without shipping a data file.
        var seed: UInt32 = 0x4C554E41  // "LUNA"
        func random() -> CGFloat {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return CGFloat(seed >> 8) / CGFloat(UInt32.max >> 8)
        }
        return (0..<starCount).map { index in
            // Cube the roll so faint stars vastly outnumber bright ones, as in a
            // real magnitude distribution.
            let brightness = pow(random(), 3)
            return Star(
                x: random(),
                y: random(),
                radius: 0.35 + brightness * 0.6,
                alpha: 0.016 + brightness * 0.115,
                bloom: index % 19 == 0)
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: StarfieldView, _) in view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    /// The star colour: the app's atmosphere tint pulled most of the way to
    /// white, so the cast is present but the stars still read as starlight.
    private var starColor: UIColor {
        LunaSurfacePalette.blended(
            LunaSurfacePalette.atmosphereTint, toward: .white, amount: 0.55)
    }

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              bounds.width > 0, bounds.height > 0
        else { return }

        let color = starColor.resolvedColor(with: traitCollection)
        // Screen blending keeps stars additive over whatever sky sits behind.
        context.setBlendMode(.screen)

        for star in Self.sky {
            let center = CGPoint(x: star.x * bounds.width, y: star.y * bounds.height)
            guard rect.insetBy(dx: -4, dy: -4).contains(center) else { continue }

            if star.bloom {
                drawBloom(context: context, center: center, color: color, star: star)
            }
            context.setFillColor(color.withAlphaComponent(star.alpha).cgColor)
            context.fillEllipse(
                in: CGRect(
                    x: center.x - star.radius,
                    y: center.y - star.radius,
                    width: star.radius * 2,
                    height: star.radius * 2))
        }
    }

    private func drawBloom(
        context: CGContext, center: CGPoint, color: UIColor, star: Star
    ) {
        let radius = star.radius * 5
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                color.withAlphaComponent(star.alpha * 0.5).cgColor,
                color.withAlphaComponent(star.alpha * 0.14).cgColor,
                color.withAlphaComponent(0).cgColor,
            ] as CFArray,
            locations: [0, 0.4, 1])
        else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: [])
    }

    // MARK: - Installation

    /// Adds a starfield behind everything already in `view`, pinned to its
    /// bounds. The caller keeps owning the view's background colour; the
    /// starfield only adds the stars.
    @discardableResult
    public static func install(behindContentsOf view: UIView) -> StarfieldView {
        let starfield = StarfieldView(frame: view.bounds)
        starfield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(starfield, at: 0)
        return starfield
    }
}
