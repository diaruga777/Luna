//
//  HalftoneSettings.swift
//  Clip
//

import UIKit
import ClipContentRendering

/// Persisted parameters for the experimental Halftone visual effect. Every value
/// is stored in the App Group so extensions could read it too, and assembled into
/// a `HalftoneConfig` on demand. Defaults mirror `HalftoneConfig.ledPanel`.
enum HalftoneSettings {

    /// User-pickable dot shapes (mirrors `HalftoneConfig.DotShape`'s cases).
    enum ShapeKind: Int, CaseIterable {
        case circle, square, rounded
        var title: String {
            switch self {
            case .circle: return "Circle"
            case .square: return "Square"
            case .rounded: return "Rounded"
            }
        }
    }

    // MARK: Slider ranges (each parameter exposed across its full sensible range)

    static let cellSizeRange: ClosedRange<Double> = 2...80
    static let dotSpacingRange: ClosedRange<Double> = 1...6
    // Dot size is decoupled from spacing, so it can exceed one cell (dots can
    // overlap their neighbours / fill the gaps left by wider spacing).
    static let dotScaleRange: ClosedRange<Double> = 0...3
    static let cornerRadiusRange: ClosedRange<Double> = 0...1
    static let edgeSoftnessRange: ClosedRange<Double> = 0.5...16
    static let jitterRange: ClosedRange<Double> = 0...1
    static let brightnessBoostRange: ClosedRange<Double> = 0...4
    static let dotOpacityRange: ClosedRange<Double> = 0...1
    static let gridAngleRange: ClosedRange<Double> = 0...(2 * .pi)
    static let gapBlurRange: ClosedRange<Double> = 0...40
    static let gapSourceMixRange: ClosedRange<Double> = 0...1
    static let gapAlphaRange: ClosedRange<Double> = 0...1

    // Ripple transition ranges.
    static let ripplePushRange: ClosedRange<Double> = 0...120
    static let rippleSpeedRange: ClosedRange<Double> = 80...3000
    static let rippleWidthRange: ClosedRange<Double> = 10...200
    static let rippleEdgeRange: ClosedRange<Double> = 1...120
    static let rippleWavelengthRange: ClosedRange<Double> = 0...200
    static let rippleDecayRange: ClosedRange<Double> = 20...400
    static let rippleDurationRange: ClosedRange<Double> = 0...3

    // Drag (finger-follow) ranges.
    static let dragRadiusRange: ClosedRange<Double> = 20...240
    static let dragStrengthRange: ClosedRange<Double> = 0...3
    static let dragMaxDistanceRange: ClosedRange<Double> = 10...200

    // MARK: Storage

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ReadingListStore.appGroupID) ?? .standard
    }

    /// Reads a Double, falling back to `fallback` when the key was never set.
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

    static var cellSize: Double {
        get { double("halftone.cellSize", 16) }
        set { defaults.set(newValue, forKey: "halftone.cellSize") }
    }
    static var dotScale: Double {
        get { double("halftone.dotScale", 0.84) }
        set { defaults.set(newValue, forKey: "halftone.dotScale") }
    }
    static var dotSpacing: Double {
        get { double("halftone.dotSpacing", 1.0) }
        set { defaults.set(newValue, forKey: "halftone.dotSpacing") }
    }
    static var shapeKind: ShapeKind {
        get { ShapeKind(rawValue: int("halftone.shapeKind", ShapeKind.rounded.rawValue)) ?? .rounded }
        set { defaults.set(newValue.rawValue, forKey: "halftone.shapeKind") }
    }
    static var cornerRadius: Double {
        get { double("halftone.cornerRadius", 0.30) }
        set { defaults.set(newValue, forKey: "halftone.cornerRadius") }
    }
    static var edgeSoftness: Double {
        get { double("halftone.edgeSoftness", 1.0) }
        set { defaults.set(newValue, forKey: "halftone.edgeSoftness") }
    }
    static var jitter: Double {
        get { double("halftone.jitter", 0) }
        set { defaults.set(newValue, forKey: "halftone.jitter") }
    }
    static var brightnessBoost: Double {
        get { double("halftone.brightnessBoost", 1.04) }
        set { defaults.set(newValue, forKey: "halftone.brightnessBoost") }
    }
    static var averageCell: Bool {
        get { bool("halftone.averageCell", true) }
        set { defaults.set(newValue, forKey: "halftone.averageCell") }
    }
    static var monochrome: Bool {
        get { bool("halftone.monochrome", false) }
        set { defaults.set(newValue, forKey: "halftone.monochrome") }
    }
    /// When on, the "off" (no-effect) state is fully transparent, so a tap ripples
    /// the dots into/out of existence over a clear background.
    static var transparentBackground: Bool {
        get { bool("halftone.transparentBackground", false) }
        set { defaults.set(newValue, forKey: "halftone.transparentBackground") }
    }
    static var dotOpacity: Double {
        get { double("halftone.dotOpacity", 1.0) }
        set { defaults.set(newValue, forKey: "halftone.dotOpacity") }
    }
    static var gridAngle: Double {
        get { double("halftone.gridAngle", 0) }
        set { defaults.set(newValue, forKey: "halftone.gridAngle") }
    }
    static var gapBlur: Double {
        get { double("halftone.gapBlur", 0) }
        set { defaults.set(newValue, forKey: "halftone.gapBlur") }
    }
    static var gapSourceMix: Double {
        get { double("halftone.gapSourceMix", 0) }
        set { defaults.set(newValue, forKey: "halftone.gapSourceMix") }
    }

    // Ripple transition parameters.
    static var ripplePush: Double {
        get { double("halftone.ripplePush", 24) }
        set { defaults.set(newValue, forKey: "halftone.ripplePush") }
    }
    static var rippleSpeed: Double {
        get { double("halftone.rippleSpeed", 1400) }
        set { defaults.set(newValue, forKey: "halftone.rippleSpeed") }
    }
    static var rippleWidth: Double {
        get { double("halftone.rippleWidth", 60) }
        set { defaults.set(newValue, forKey: "halftone.rippleWidth") }
    }
    static var rippleEdge: Double {
        get { double("halftone.rippleEdge", 24) }
        set { defaults.set(newValue, forKey: "halftone.rippleEdge") }
    }
    static var rippleWavelength: Double {
        get { double("halftone.rippleWavelength", 70) }
        set { defaults.set(newValue, forKey: "halftone.rippleWavelength") }
    }
    static var rippleDecay: Double {
        get { double("halftone.rippleDecay", 120) }
        set { defaults.set(newValue, forKey: "halftone.rippleDecay") }
    }
    static var rippleDuration: Double {
        get { double("halftone.rippleDuration", 0) }
        set { defaults.set(newValue, forKey: "halftone.rippleDuration") }
    }

    // Drag (finger-follow) parameters.
    static var dragRadius: Double {
        get { double("halftone.dragRadius", 90) }
        set { defaults.set(newValue, forKey: "halftone.dragRadius") }
    }
    static var dragStrength: Double {
        get { double("halftone.dragStrength", 1.0) }
        set { defaults.set(newValue, forKey: "halftone.dragStrength") }
    }
    static var dragMaxDistance: Double {
        get { double("halftone.dragMaxDistance", 70) }
        set { defaults.set(newValue, forKey: "halftone.dragMaxDistance") }
    }

    // Gap color stored as RGBA components (default opaque black).
    static var gapColorRed: Double {
        get { double("halftone.gapColor.r", 0) }
        set { defaults.set(newValue, forKey: "halftone.gapColor.r") }
    }
    static var gapColorGreen: Double {
        get { double("halftone.gapColor.g", 0) }
        set { defaults.set(newValue, forKey: "halftone.gapColor.g") }
    }
    static var gapColorBlue: Double {
        get { double("halftone.gapColor.b", 0) }
        set { defaults.set(newValue, forKey: "halftone.gapColor.b") }
    }
    static var gapColorAlpha: Double {
        get { double("halftone.gapColor.a", 1) }
        set { defaults.set(newValue, forKey: "halftone.gapColor.a") }
    }

    static var gapColor: UIColor {
        get {
            UIColor(red: CGFloat(gapColorRed), green: CGFloat(gapColorGreen),
                    blue: CGFloat(gapColorBlue), alpha: CGFloat(gapColorAlpha))
        }
        set {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            newValue.getRed(&r, green: &g, blue: &b, alpha: &a)
            gapColorRed = Double(r); gapColorGreen = Double(g)
            gapColorBlue = Double(b); gapColorAlpha = Double(a)
        }
    }

    // MARK: Build the effect config

    /// Assemble a `HalftoneConfig` from the currently persisted parameters.
    static var currentConfig: HalftoneConfig {
        var c = HalftoneConfig()
        c.cellSize = CGFloat(cellSize)
        c.dotScale = CGFloat(dotScale)
        c.dotSpacing = CGFloat(dotSpacing)
        switch shapeKind {
        case .circle: c.shape = .circle
        case .square: c.shape = .square
        case .rounded: c.shape = .roundedSquare(cornerRadius: CGFloat(cornerRadius))
        }
        c.edgeSoftness = CGFloat(edgeSoftness)
        c.jitter = CGFloat(jitter)
        c.brightnessBoost = CGFloat(brightnessBoost)
        c.averageCell = averageCell
        c.monochrome = monochrome
        c.transparentBackground = transparentBackground
        c.dotOpacity = CGFloat(dotOpacity)
        c.gridAngle = CGFloat(gridAngle)
        c.gapColor = gapColor
        c.gapBlur = CGFloat(gapBlur)
        c.gapSourceMix = CGFloat(gapSourceMix)
        // The effect only ever captures a single-content stage via CARenderer, whose
        // per-layer content inversion is a plain global vertical flip here — undo it.
        c.sourceFlippedOverride = true
        c.ripplePushDistance = CGFloat(ripplePush)
        c.rippleSpeed = CGFloat(rippleSpeed)
        c.rippleWidth = CGFloat(rippleWidth)
        c.rippleEdge = CGFloat(rippleEdge)
        c.rippleWavelength = CGFloat(rippleWavelength)
        c.rippleDecay = CGFloat(rippleDecay)
        c.rippleDuration = TimeInterval(rippleDuration)
        c.dragRadius = CGFloat(dragRadius)
        c.dragStrength = CGFloat(dragStrength)
        c.dragMaxDistance = CGFloat(dragMaxDistance)
        return c
    }
}
