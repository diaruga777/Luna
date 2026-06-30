//
//  StoneSettings.swift
//  Lune
//

import LuneStorage
import UIKit
import LuneContentRendering

/// Persisted parameters for a "stone" visual effect (Jellystone sea-glass or
/// Lune). One store per material, namespaced so the two effects keep independent
/// settings. Assembled into a `StoneConfig` on demand.
struct StoneSettings {

    let material: StoneConfig.Material
    init(_ material: StoneConfig.Material) { self.material = material }

    // MARK: Slider ranges (shared by both materials)

    static let blurRange: ClosedRange<Double> = 0...30
    static let grainRange: ClosedRange<Double> = 0...1
    static let distortionRange: ClosedRange<Double> = 0...40       // refraction strength, px
    static let translucencyRange: ClosedRange<Double> = 0...1
    static let surfaceScaleRange: ClosedRange<Double> = 8...200    // surface feature size, px
    static let saturationRange: ClosedRange<Double> = 0...2
    static let brightnessRange: ClosedRange<Double> = 0.5...1.6

    static let ripplePushRange: ClosedRange<Double> = 0...120
    static let rippleSpeedRange: ClosedRange<Double> = 80...3000
    static let rippleWidthRange: ClosedRange<Double> = 10...200
    static let rippleEdgeRange: ClosedRange<Double> = 1...120
    static let rippleWavelengthRange: ClosedRange<Double> = 0...200
    static let rippleDecayRange: ClosedRange<Double> = 20...400
    static let rippleDurationRange: ClosedRange<Double> = 0...3
    static let revealAngleRange: ClosedRange<Double> = 0...(2 * .pi)
    static let chromaticRange: ClosedRange<Double> = 0...12
    static let scanlineStrengthRange: ClosedRange<Double> = 0...1
    static let scanlineSpacingRange: ClosedRange<Double> = 2...20

    // MARK: Storage

    private var prefix: String { material == .jellystone ? "stone.jelly." : "stone.lune." }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: ReadingListStore.appGroupID) ?? .standard
    }
    private func double(_ key: String, _ fallback: Double) -> Double {
        let k = prefix + key
        return defaults.object(forKey: k) == nil ? fallback : defaults.double(forKey: k)
    }
    private func int(_ key: String, _ fallback: Int) -> Int {
        let k = prefix + key
        return defaults.object(forKey: k) == nil ? fallback : defaults.integer(forKey: k)
    }
    private func set(_ value: Double, _ key: String) { defaults.set(value, forKey: prefix + key) }
    private func set(_ value: Int, _ key: String) { defaults.set(value, forKey: prefix + key) }

    // MARK: Per-material defaults

    private var defaultTint: UIColor {
        material == .jellystone
            ? UIColor(red: 0.55, green: 0.85, blue: 0.78, alpha: 0.55)   // sea-glass green
            : UIColor(red: 0.86, green: 0.89, blue: 0.96, alpha: 0.35)   // cool milky lune
    }
    private var defaultSaturation: Double { material == .jellystone ? 1.15 : 0.85 }
    private var defaultBrightness: Double { material == .jellystone ? 1.06 : 1.14 }

    // MARK: Properties

    var blurRadius: Double {
        get { double("blur", 8) } nonmutating set { set(newValue, "blur") }
    }
    var grain: Double {
        get { double("grain", 0.3) } nonmutating set { set(newValue, "grain") }
    }
    var distortion: Double {
        get { double("distortion", 10) } nonmutating set { set(newValue, "distortion") }
    }
    var translucency: Double {
        get { double("translucency", 0.6) } nonmutating set { set(newValue, "translucency") }
    }
    var surfaceScale: Double {
        get { double("surfaceScale", 50) } nonmutating set { set(newValue, "surfaceScale") }
    }
    var saturation: Double {
        get { double("saturation", defaultSaturation) } nonmutating set { set(newValue, "saturation") }
    }
    var brightness: Double {
        get { double("brightness", defaultBrightness) } nonmutating set { set(newValue, "brightness") }
    }

    var tintRed: Double {
        get { double("tint.r", defaultTint.rgbaComponents.r) } nonmutating set { set(newValue, "tint.r") }
    }
    var tintGreen: Double {
        get { double("tint.g", defaultTint.rgbaComponents.g) } nonmutating set { set(newValue, "tint.g") }
    }
    var tintBlue: Double {
        get { double("tint.b", defaultTint.rgbaComponents.b) } nonmutating set { set(newValue, "tint.b") }
    }
    var tintAlpha: Double {
        get { double("tint.a", defaultTint.rgbaComponents.a) } nonmutating set { set(newValue, "tint.a") }
    }
    var tint: UIColor {
        get { UIColor(red: tintRed, green: tintGreen, blue: tintBlue, alpha: tintAlpha) }
        nonmutating set {
            let c = newValue.rgbaComponents
            tintRed = c.r; tintGreen = c.g; tintBlue = c.b; tintAlpha = c.a
        }
    }

    var ripplePush: Double {
        get { double("ripplePush", 24) } nonmutating set { set(newValue, "ripplePush") }
    }
    var rippleSpeed: Double {
        get { double("rippleSpeed", 1200) } nonmutating set { set(newValue, "rippleSpeed") }
    }
    var rippleWidth: Double {
        get { double("rippleWidth", 70) } nonmutating set { set(newValue, "rippleWidth") }
    }
    var rippleEdge: Double {
        get { double("rippleEdge", 40) } nonmutating set { set(newValue, "rippleEdge") }
    }
    var rippleWavelength: Double {
        get { double("rippleWavelength", 80) } nonmutating set { set(newValue, "rippleWavelength") }
    }
    var rippleDecay: Double {
        get { double("rippleDecay", 140) } nonmutating set { set(newValue, "rippleDecay") }
    }
    var rippleDuration: Double {
        get { double("rippleDuration", 0) } nonmutating set { set(newValue, "rippleDuration") }
    }
    var revealMode: StoneConfig.RevealMode {
        get { StoneConfig.RevealMode(rawValue: int("revealMode", 0)) ?? .radial }
        nonmutating set { set(newValue.rawValue, "revealMode") }
    }
    var revealAngle: Double {
        get { double("revealAngle", 0) } nonmutating set { set(newValue, "revealAngle") }
    }
    var chromaticAberration: Double {
        get { double("chromatic", 0) } nonmutating set { set(newValue, "chromatic") }
    }
    var scanlineStrength: Double {
        get { double("scanlineStrength", 0) } nonmutating set { set(newValue, "scanlineStrength") }
    }
    var scanlineSpacing: Double {
        get { double("scanlineSpacing", 4) } nonmutating set { set(newValue, "scanlineSpacing") }
    }

    // MARK: Build the effect config

    var currentConfig: StoneConfig {
        var c = StoneConfig()
        c.material = material
        c.blurRadius = CGFloat(blurRadius)
        c.grain = CGFloat(grain)
        c.distortion = CGFloat(distortion)
        c.translucency = CGFloat(translucency)
        c.surfaceScale = CGFloat(surfaceScale)
        c.tint = tint
        c.saturation = CGFloat(saturation)
        c.brightness = CGFloat(brightness)
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

private extension UIColor {
    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }
}
