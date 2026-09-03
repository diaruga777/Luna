//
//  VisualAngle.swift
//  LunaGaze
//

import CoreGraphics
import Foundation
import UIKit

/// Converts between degrees of visual angle and screen points.
///
/// Every threshold in the reading pipeline is stated in degrees, because that
/// is the unit the eye works in: the same 60 points is a coarse threshold on a
/// phone held close and a fine one on an iPad held at arm's length. A session
/// converts once, at the reading distance it assumes, and then works in points.
public enum VisualAngle {

    /// Distance from the eyes to the display assumed when nothing better is
    /// known. Measured reading distances cluster near 40 cm on a phone.
    public static let typicalReadingDistanceMetres: CGFloat = 0.4

    /// Points subtended by an angle at a distance.
    public static func points(
        degrees: CGFloat, distanceMetres: CGFloat, pointsPerMetre: CGFloat
    ) -> CGFloat {
        pointsPerMetre * distanceMetres * CGFloat(tan(Double(degrees) * .pi / 180))
    }

    /// Points subtended by an angle on this idiom's display.
    public static func points(
        degrees: CGFloat,
        distanceMetres: CGFloat = VisualAngle.typicalReadingDistanceMetres,
        idiom: UIUserInterfaceIdiom
    ) -> CGFloat {
        points(
            degrees: degrees,
            distanceMetres: distanceMetres,
            pointsPerMetre: GazeScreenProjection.pointsPerMetre(idiom: idiom))
    }

    /// The one conversion factor a session needs: points per degree.
    public static func pointsPerDegree(
        distanceMetres: CGFloat = VisualAngle.typicalReadingDistanceMetres,
        pointsPerMetre: CGFloat
    ) -> CGFloat {
        points(degrees: 1, distanceMetres: distanceMetres, pointsPerMetre: pointsPerMetre)
    }

    /// The one conversion factor a session needs, for this idiom's display.
    public static func pointsPerDegree(
        distanceMetres: CGFloat = VisualAngle.typicalReadingDistanceMetres,
        idiom: UIUserInterfaceIdiom
    ) -> CGFloat {
        points(degrees: 1, distanceMetres: distanceMetres, idiom: idiom)
    }

    /// Degrees subtended by a distance in points.
    public static func degrees(
        points value: CGFloat, distanceMetres: CGFloat, pointsPerMetre: CGFloat
    ) -> CGFloat {
        let metres = value / max(pointsPerMetre, 1e-6)
        return CGFloat(atan(Double(metres / max(distanceMetres, 1e-6))) * 180 / .pi)
    }
}
