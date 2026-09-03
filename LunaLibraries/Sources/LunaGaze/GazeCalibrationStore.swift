//
//  GazeCalibrationStore.swift
//  LunaGaze
//

import CoreGraphics
import Foundation

/// Keeps one calibration per interface orientation.
///
/// A fit is orientation-specific: rotating the device moves the camera to the
/// side of the display and changes the whole geometry, so a portrait fit
/// applied in landscape is worse than no fit at all. Rotating back must not
/// cost the reader another sweep, so both are kept.
public final class GazeCalibrationStore {

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "luna.gaze.affine.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func calibration(for orientation: GazeOrientation) -> GazeAffineCalibration? {
        guard let stored = defaults.dictionary(forKey: key) as? [String: Data],
              let data = stored[Self.slot(for: orientation)]
        else { return nil }
        return try? JSONDecoder().decode(GazeAffineCalibration.self, from: data)
    }

    public func save(_ calibration: GazeAffineCalibration, for orientation: GazeOrientation) {
        guard let data = try? JSONEncoder().encode(calibration) else { return }
        var stored = (defaults.dictionary(forKey: key) as? [String: Data]) ?? [:]
        stored[Self.slot(for: orientation)] = data
        defaults.set(stored, forKey: key)
    }

    public func remove(for orientation: GazeOrientation) {
        guard var stored = defaults.dictionary(forKey: key) as? [String: Data] else { return }
        stored[Self.slot(for: orientation)] = nil
        defaults.set(stored, forKey: key)
    }

    public func removeAll() {
        defaults.removeObject(forKey: key)
    }

    /// One slot per orientation.
    static func slot(for orientation: GazeOrientation) -> String {
        switch orientation {
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .portrait: return "portrait"
        }
    }
}
