//
//  PlaybackSpeed.swift
//  LunaDesignSystem
//
//  The ONE set of playback speeds Luna's own players offer, and the in-memory
//  place a chosen speed is remembered per item.
//
//  Every Luna surface that plays media with its OWN controls (the carousel
//  card players) reads both from here, so a speed picked on one surface reads
//  the same and lands the same everywhere. Surfaces that hand playback to
//  `AVPlayerViewController` keep the SYSTEM speed menu instead of drawing a
//  second one — they only seed and record the remembered value.
//

import Foundation
import LunaModels

public enum PlaybackSpeed {

    /// Normal speed — what an item plays at until the user says otherwise.
    public static let normal: Double = 1

    /// The offered speeds, slowest first, as they appear in the pill's menu.
    public static let options: [Double] = [0.25, 0.5, 1, 1.5, 2]

    /// "1×", "0.25×" — `%g` drops the trailing zeros, so 1.5 reads "1.5×" and
    /// 1 reads "1×" rather than "1.0×".
    public static func label(for speed: Double) -> String {
        String(format: "%g×", speed)
    }

    /// A speech-friendly form for accessibility labels ("0.5× speed").
    public static func accessibilityLabel(for speed: Double) -> String {
        let formatted = String(format: "%g", speed)
        return L10n.string("\(formatted)× speed")
    }

    /// Whether two speeds are the same choice, tolerating float representation.
    public static func matches(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.001
    }
}

/// Playback speed per item, for **this run of the app only**.
///
/// Deliberately not persisted: a speed is a way of watching one thing right
/// now (skim this clip at 2×, study that one at 0.5×), not a preference the
/// user set once and owns forever. It lives long enough that paging away from
/// a card and back — or reopening the same item fullscreen — keeps the speed
/// the user just chose, and dies with the process.
///
/// Main-thread only, like the players that read it.
public final class PlaybackSpeedMemory {

    public static let shared = PlaybackSpeedMemory()

    private var speeds: [String: Double] = [:]

    public init() {}

    /// The remembered speed for `key`, or normal speed when nothing is
    /// remembered (or the caller has no key to remember by).
    public func speed(forKey key: String?) -> Double {
        guard let key, let speed = speeds[key] else { return PlaybackSpeed.normal }
        return speed
    }

    /// Remembers `speed` for `key`. Normal speed is stored like any other, so a
    /// deliberate return to 1× survives paging away just as 2× does.
    public func setSpeed(_ speed: Double, forKey key: String?) {
        guard let key else { return }
        speeds[key] = speed
    }

    /// Forgets everything — for tests, and for a store that drops its items.
    public func reset() {
        speeds.removeAll()
    }
}
