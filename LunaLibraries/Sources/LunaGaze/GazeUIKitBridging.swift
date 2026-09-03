//
//  GazeUIKitBridging.swift
//  LunaGaze
//

// Platform gate, not the per-target gate CLAUDE.md forbids: everything here
// exists only to translate UIKit's orientation and idiom types into the pure
// `GazeOrientation`/`GazeDeviceClass` the geometry actually runs on, so a
// non-UIKit host (a `swift build` for macOS, or a future AppKit target)
// still links `GazeScreenProjection`, `VisualAngle` and `GazeCalibrationStore`.
#if canImport(UIKit)
import CoreGraphics
import UIKit

extension GazeDeviceClass {
    public init(_ idiom: UIUserInterfaceIdiom) {
        self = idiom == .pad ? .pad : .phone
    }
}

extension GazeOrientation {
    public init(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: self = .portrait
        }
    }
}

extension GazeScreenProjection {

    public static func pointsPerMetre(idiom: UIUserInterfaceIdiom) -> CGFloat {
        pointsPerMetre(deviceClass: GazeDeviceClass(idiom))
    }

    static func pointsPerInch(idiom: UIUserInterfaceIdiom) -> CGFloat {
        pointsPerInch(deviceClass: GazeDeviceClass(idiom))
    }

    public static func pointsPerMetre(
        idiom: UIUserInterfaceIdiom, nativeScale: CGFloat, portraitPointSize: CGSize
    ) -> CGFloat {
        pointsPerMetre(
            deviceClass: GazeDeviceClass(idiom), nativeScale: nativeScale, portraitPointSize: portraitPointSize)
    }

    static func pointsPerInch(
        idiom: UIUserInterfaceIdiom, nativeScale: CGFloat, portraitPointSize: CGSize
    ) -> CGFloat {
        pointsPerInch(
            deviceClass: GazeDeviceClass(idiom), nativeScale: nativeScale, portraitPointSize: portraitPointSize)
    }

    public static func orientedScreenPoint(
        fromPortraitPoint point: CGPoint,
        portraitSize: CGSize,
        orientation: UIInterfaceOrientation
    ) -> CGPoint {
        orientedScreenPoint(
            fromPortraitPoint: point, portraitSize: portraitSize, orientation: GazeOrientation(orientation))
    }

    public static func orientedSize(
        portraitSize: CGSize, orientation: UIInterfaceOrientation
    ) -> CGSize {
        orientedSize(portraitSize: portraitSize, orientation: GazeOrientation(orientation))
    }
}

extension VisualAngle {

    public static func points(
        degrees: CGFloat,
        distanceMetres: CGFloat = VisualAngle.typicalReadingDistanceMetres,
        idiom: UIUserInterfaceIdiom
    ) -> CGFloat {
        points(degrees: degrees, distanceMetres: distanceMetres, deviceClass: GazeDeviceClass(idiom))
    }

    public static func pointsPerDegree(
        distanceMetres: CGFloat = VisualAngle.typicalReadingDistanceMetres,
        idiom: UIUserInterfaceIdiom
    ) -> CGFloat {
        pointsPerDegree(distanceMetres: distanceMetres, deviceClass: GazeDeviceClass(idiom))
    }
}

extension GazeCalibrationStore {

    public func calibration(for orientation: UIInterfaceOrientation) -> GazeAffineCalibration? {
        calibration(for: GazeOrientation(orientation))
    }

    public func save(_ calibration: GazeAffineCalibration, for orientation: UIInterfaceOrientation) {
        save(calibration, for: GazeOrientation(orientation))
    }

    public func remove(for orientation: UIInterfaceOrientation) {
        remove(for: GazeOrientation(orientation))
    }
}
#endif
