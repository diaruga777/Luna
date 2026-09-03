//
//  GazeScreenProjection.swift
//  LunaGaze
//

import CoreGraphics
import simd
import UIKit

/// Turns a gaze ray expressed in ARKit's camera space into a point on the
/// display, in `UIScreen.fixedCoordinateSpace` (portrait-origin) points.
///
/// Kept free of ARKit so the geometry can be unit-tested on the simulator,
/// where face tracking is never available.
///
/// **Camera space.** ARKit's camera looks down −z with +y up, and
/// `ARCamera.viewMatrix(for: .portrait)` orients that frame to the device held
/// upright. The front camera therefore has the user at NEGATIVE z, and the
/// display itself lies in the z = 0 plane. Because the frame is right-handed
/// with −z pointing at the user, +x runs toward the user's view of the screen's
/// LEFT — hence the negation below rather than a straight copy.
///
/// **Scale.** iPhone displays are laid out at ~163 UIKit points per inch and
/// iPads at ~132, across every model, so points-per-metre needs no per-device
/// table. The front camera sits a few millimetres above the top of the display,
/// which is the only other physical constant this needs.
public enum GazeScreenProjection {

    /// UIKit points per inch, by idiom. A single constant per idiom, used
    /// where no screen metrics are available yet (a default argument's
    /// evaluation point, mostly).
    public static func pointsPerMetre(idiom: UIUserInterfaceIdiom) -> CGFloat {
        pointsPerInch(idiom: idiom) / 0.0254
    }

    static func pointsPerInch(idiom: UIUserInterfaceIdiom) -> CGFloat {
        idiom == .pad ? 132 : 163
    }

    /// UIKit points per inch, derived from the physical pixel density of the
    /// known display families rather than one constant per idiom.
    ///
    /// `nativeScale` alone tells 2×/3× apart; within 2×, the iPad mini shares
    /// the iPhone's ~326ppi panel rather than the ~264ppi panel every larger
    /// iPad uses, so it needs its point width to tell the two apart. Within
    /// 3×, the Plus-size iPhones run a ~401ppi panel rather than the
    /// Pro-class ~458ppi one, and again the point width is what tells them
    /// apart. A shape this function does not recognise falls back to the
    /// idiom-only constant.
    public static func pointsPerMetre(
        idiom: UIUserInterfaceIdiom, nativeScale: CGFloat, portraitPointSize: CGSize
    ) -> CGFloat {
        pointsPerInch(idiom: idiom, nativeScale: nativeScale, portraitPointSize: portraitPointSize)
            / 0.0254
    }

    static func pointsPerInch(
        idiom: UIUserInterfaceIdiom, nativeScale: CGFloat, portraitPointSize: CGSize
    ) -> CGFloat {
        let shortSide = min(portraitPointSize.width, portraitPointSize.height)
        switch idiom {
        case .pad:
            guard nativeScale >= 1.9 else { return pointsPerInch(idiom: idiom) }
            return shortSide > 0 && shortSide < 780 ? 163 : 132
        default:
            guard nativeScale >= 2.9 else { return pointsPerInch(idiom: idiom) }
            return shortSide >= 420 ? 134 : 153
        }
    }

    /// Distance in metres from the front camera's optical centre down to the
    /// top edge of the display. A single approximation for every device: it
    /// shifts the whole estimate by ~40 points, well inside the tolerance the
    /// generous focus radius is built for.
    public static let cameraHeightAboveScreen: CGFloat = 0.006

    /// Longest a gaze ray may travel before it hits the display plane. A hit
    /// past this is a near-parallel ray the guard below let through by
    /// arithmetic accident, not a real fixation anywhere on the device.
    public static let maximumRayTravel: Float = 2.0

    /// Intersects the gaze ray with the plane of the display.
    ///
    /// - Parameters:
    ///   - eyeOrigin: midpoint between the eyes, in camera space (metres).
    ///   - lookAt: the gaze target, in camera space (metres).
    ///   - cameraPosition: where the front camera sits along the portrait
    ///     display's top edge, as a fraction of (width, height). Defaults to
    ///     top-centre; a device whose camera sits elsewhere (a long edge, on
    ///     some iPads) needs its own value here.
    /// - Returns: the point in portrait-origin screen points, or nil when the
    ///   ray runs away from the display, or travels implausibly far to reach
    ///   it, instead of meeting it nearby.
    public static func screenPoint(
        eyeOrigin: SIMD3<Float>,
        lookAt: SIMD3<Float>,
        screenSize: CGSize,
        pointsPerMetre: CGFloat,
        cameraHeightAboveScreen: CGFloat = GazeScreenProjection.cameraHeightAboveScreen,
        cameraPosition: CGPoint = CGPoint(x: 0.5, y: 0)
    ) -> CGPoint? {
        let direction = lookAt - eyeOrigin
        // The user sits at negative z and the screen is at z = 0, so a gaze
        // aimed anywhere near the device travels in +z. A ray with no forward
        // component (or pointing further away) never meets the display plane.
        guard direction.z > 1e-6 else { return nil }
        let distanceAlongRay = -eyeOrigin.z / direction.z
        guard distanceAlongRay > 0, distanceAlongRay.isFinite else { return nil }
        guard simd_length(direction) * distanceAlongRay <= maximumRayTravel else { return nil }
        let hit = eyeOrigin + direction * distanceAlongRay

        return CGPoint(
            x: screenSize.width * cameraPosition.x - CGFloat(hit.x) * pointsPerMetre,
            y: screenSize.height * cameraPosition.y
                + (-CGFloat(hit.y) - cameraHeightAboveScreen) * pointsPerMetre)
    }

    /// Rotates a portrait-fixed screen point into the screen coordinates the
    /// interface is currently presented in.
    ///
    /// This is done by hand rather than through
    /// `UIScreen.fixedCoordinateSpace.convert(_:to:)` because that conversion
    /// needs a window attached to a scene, which is precisely what a unit test
    /// (and any headless layout pass) does not have — it silently collapses to
    /// the origin instead of failing.
    ///
    /// - Parameter portraitSize: the display's size held upright.
    public static func orientedScreenPoint(
        fromPortraitPoint point: CGPoint,
        portraitSize: CGSize,
        orientation: UIInterfaceOrientation
    ) -> CGPoint {
        switch orientation {
        case .portraitUpsideDown:
            return CGPoint(x: portraitSize.width - point.x, y: portraitSize.height - point.y)
        case .landscapeLeft:
            // Home-button edge to the right: the device's top edge runs down
            // the screen's left, so portrait-y becomes screen-x.
            return CGPoint(x: point.y, y: portraitSize.width - point.x)
        case .landscapeRight:
            return CGPoint(x: portraitSize.height - point.y, y: point.x)
        default:
            return point
        }
    }

    /// Rotates a portrait-fixed screen SIZE the same way `orientedScreenPoint`
    /// rotates a point — landscape swaps width and height.
    ///
    /// `GazeGate.screenSize` must be given a size from this function, not the
    /// raw portrait size: the gate's on-screen test compares it against a
    /// point already rotated by `orientedScreenPoint`, and the two must agree
    /// on which axis is which.
    public static func orientedSize(
        portraitSize: CGSize, orientation: UIInterfaceOrientation
    ) -> CGSize {
        switch orientation {
        case .landscapeLeft, .landscapeRight:
            return CGSize(width: portraitSize.height, height: portraitSize.width)
        default:
            return portraitSize
        }
    }

    /// Whether a projected point counts as "on the display". The margin absorbs
    /// the estimator's error at the edges: a reader looking at the very bottom
    /// of the screen should not be classified as looking past the phone.
    public static func isOnScreen(
        _ point: CGPoint, screenSize: CGSize, margin: CGFloat = 60
    ) -> Bool {
        point.x >= -margin && point.x <= screenSize.width + margin
            && point.y >= -margin && point.y <= screenSize.height + margin
    }
}
