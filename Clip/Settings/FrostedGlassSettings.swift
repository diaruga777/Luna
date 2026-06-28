//
//  FrostedGlassSettings.swift
//  Clip
//

import ClipStorage
import UIKit
import ClipContentRendering

/// Persisted parameters for the experimental Frosted-Glass-Neon visual effect.
/// Every value is stored in the App Group and assembled into a `FrostedGlassConfig`
/// on demand. Defaults mirror `FrostedGlassConfig()`.
enum FrostedGlassSettings {

    // MARK: Slider ranges

    static let frostRadiusRange: ClosedRange<Double> = 0...30
    static let frostScatterRange: ClosedRange<Double> = 0...1
    static let glowThresholdRange: ClosedRange<Double> = 0...1
    static let glowIntensityRange: ClosedRange<Double> = 0...3
    static let glowRadiusRange: ClosedRange<Double> = 0...50
    static let saturationRange: ClosedRange<Double> = 0...3
    static let brightnessRange: ClosedRange<Double> = 0.4...2
    static let tintAlphaRange: ClosedRange<Double> = 0...1

    // Ripple transition ranges.
    static let ripplePushRange: ClosedRange<Double> = 0...120
    static let rippleSpeedRange: ClosedRange<Double> = 400...3000
    static let rippleWidthRange: ClosedRange<Double> = 10...200
    static let rippleEdgeRange: ClosedRange<Double> = 4...100
    static let rippleWavelengthRange: ClosedRange<Double> = 0...200
    static let rippleDecayRange: ClosedRange<Double> = 20...400
    static let rippleDurationRange: ClosedRange<Double> = 0...3

    // MARK: Storage

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ReadingListStore.appGroupID) ?? .standard
    }

    private static func double(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
    private static func int(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    // MARK: Properties

    static var frostRadius: Double {
        get { double("frosted.frostRadius", 10) }
        set { defaults.set(newValue, forKey: "frosted.frostRadius") }
    }
    static var frostScatter: Double {
        get { double("frosted.frostScatter", 0.5) }
        set { defaults.set(newValue, forKey: "frosted.frostScatter") }
    }
    static var glowThreshold: Double {
        get { double("frosted.glowThreshold", 0.55) }
        set { defaults.set(newValue, forKey: "frosted.glowThreshold") }
    }
    static var glowIntensity: Double {
        get { double("frosted.glowIntensity", 1.4) }
        set { defaults.set(newValue, forKey: "frosted.glowIntensity") }
    }
    static var glowRadius: Double {
        get { double("frosted.glowRadius", 22) }
        set { defaults.set(newValue, forKey: "frosted.glowRadius") }
    }
    static var saturation: Double {
        get { double("frosted.saturation", 1.3) }
        set { defaults.set(newValue, forKey: "frosted.saturation") }
    }
    static var brightness: Double {
        get { double("frosted.brightness", 1.0) }
        set { defaults.set(newValue, forKey: "frosted.brightness") }
    }
    static var additiveGlow: Bool {
        get { bool("frosted.additiveGlow", false) }
        set { defaults.set(newValue, forKey: "frosted.additiveGlow") }
    }

    // Tint stored as RGBA components (default neon cyan, 60% strength).
    static var tintRed: Double {
        get { double("frosted.tint.r", 0.35) }
        set { defaults.set(newValue, forKey: "frosted.tint.r") }
    }
    static var tintGreen: Double {
        get { double("frosted.tint.g", 0.8) }
        set { defaults.set(newValue, forKey: "frosted.tint.g") }
    }
    static var tintBlue: Double {
        get { double("frosted.tint.b", 1.0) }
        set { defaults.set(newValue, forKey: "frosted.tint.b") }
    }
    static var tintAlpha: Double {
        get { double("frosted.tint.a", 0.6) }
        set { defaults.set(newValue, forKey: "frosted.tint.a") }
    }
    static var tint: UIColor {
        get {
            UIColor(red: CGFloat(tintRed), green: CGFloat(tintGreen),
                    blue: CGFloat(tintBlue), alpha: CGFloat(tintAlpha))
        }
        set {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            newValue.getRed(&r, green: &g, blue: &b, alpha: &a)
            tintRed = Double(r); tintGreen = Double(g); tintBlue = Double(b); tintAlpha = Double(a)
        }
    }

    static var ripplePush: Double {
        get { double("frosted.ripplePush", 28) }
        set { defaults.set(newValue, forKey: "frosted.ripplePush") }
    }
    static var rippleSpeed: Double {
        get { double("frosted.rippleSpeed", 1400) }
        set { defaults.set(newValue, forKey: "frosted.rippleSpeed") }
    }
    static var rippleWidth: Double {
        get { double("frosted.rippleWidth", 70) }
        set { defaults.set(newValue, forKey: "frosted.rippleWidth") }
    }
    static var rippleEdge: Double {
        get { double("frosted.rippleEdge", 40) }
        set { defaults.set(newValue, forKey: "frosted.rippleEdge") }
    }
    static var rippleWavelength: Double {
        get { double("frosted.rippleWavelength", 80) }
        set { defaults.set(newValue, forKey: "frosted.rippleWavelength") }
    }
    static var rippleDecay: Double {
        get { double("frosted.rippleDecay", 140) }
        set { defaults.set(newValue, forKey: "frosted.rippleDecay") }
    }
    static var rippleDuration: Double {
        get { double("frosted.rippleDuration", 0) }
        set { defaults.set(newValue, forKey: "frosted.rippleDuration") }
    }
    static var revealMode: FrostedGlassConfig.RevealMode {
        get { FrostedGlassConfig.RevealMode(rawValue: int("frosted.revealMode", 0)) ?? .radial }
        set { defaults.set(newValue.rawValue, forKey: "frosted.revealMode") }
    }
    static var revealAngle: Double {
        get { double("frosted.revealAngle", 0) }
        set { defaults.set(newValue, forKey: "frosted.revealAngle") }
    }
    static let revealAngleRange: ClosedRange<Double> = 0...(2 * .pi)

    // Stylize parameters.
    static let chromaticRange: ClosedRange<Double> = 0...12
    static let scanlineStrengthRange: ClosedRange<Double> = 0...1
    static let scanlineSpacingRange: ClosedRange<Double> = 2...20

    static var chromaticAberration: Double {
        get { double("frosted.chromaticAberration", 0) }
        set { defaults.set(newValue, forKey: "frosted.chromaticAberration") }
    }
    static var scanlineStrength: Double {
        get { double("frosted.scanlineStrength", 0) }
        set { defaults.set(newValue, forKey: "frosted.scanlineStrength") }
    }
    static var scanlineSpacing: Double {
        get { double("frosted.scanlineSpacing", 4) }
        set { defaults.set(newValue, forKey: "frosted.scanlineSpacing") }
    }

    // MARK: Build the effect config

    static var currentConfig: FrostedGlassConfig {
        var c = FrostedGlassConfig()
        c.frostRadius = CGFloat(frostRadius)
        c.frostScatter = CGFloat(frostScatter)
        c.glowThreshold = CGFloat(glowThreshold)
        c.glowIntensity = CGFloat(glowIntensity)
        c.glowRadius = CGFloat(glowRadius)
        c.saturation = CGFloat(saturation)
        c.brightness = CGFloat(brightness)
        c.tint = tint
        c.additiveGlow = additiveGlow
        // Single-content stage captured via CARenderer → undo the global flip.
        c.sourceFlippedOverride = true
        c.ripplePushDistance = CGFloat(ripplePush)
        c.rippleSpeed = CGFloat(rippleSpeed)
        c.rippleWidth = CGFloat(rippleWidth)
        c.rippleEdge = CGFloat(rippleEdge)
        c.rippleWavelength = CGFloat(rippleWavelength)
        c.rippleDecay = CGFloat(rippleDecay)
        c.rippleDuration = TimeInterval(rippleDuration)
        c.revealMode = revealMode
        c.revealAngle = CGFloat(revealAngle)
        c.chromaticAberration = CGFloat(chromaticAberration)
        c.scanlineStrength = CGFloat(scanlineStrength)
        c.scanlineSpacing = CGFloat(scanlineSpacing)
        return c
    }
}
