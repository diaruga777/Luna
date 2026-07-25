//
//  LunaSky.swift
//  LunaDesignSystem
//

import UIKit

/// Which of Luna's two night skies a view renders against.
public enum LunaSky: Int, Equatable, Sendable, CaseIterable {
    /// True black — the "Dark" appearance.
    case night
    /// Near-black, lifted one notch and faintly tinted — the "Light" appearance.
    /// See `LunaSurfacePalette.predawnSurface(level:)`.
    case predawn
}

/// The trait that carries the sky.
///
/// Both Luna appearances are night (see `LunaColors`), which makes
/// `userInterfaceStyle` the wrong thing to hang them on: UIKit's own materials —
/// Liquid Glass, blur effects, alerts and action sheets, keyboards, scroll
/// indicators, text selection — key off it and render *light* under a light
/// trait. Pinning it to a light style produced a white glass bar carrying
/// near-white Luna text.
///
/// So `userInterfaceStyle` stays pinned to `.dark` app-wide, and the sky travels
/// on this trait instead. Because `affectsColorAppearance` is true, UIKit
/// re-resolves dynamic colours on a sky change exactly as it would on a style
/// change, which is what lets the in-app appearance switch keep repainting a live
/// hierarchy rather than rebuilding it. Views that cache resolved `CGColor`s must
/// list `LunaSkyTrait.self` in their `registerForTraitChanges` set — a style
/// change will never arrive again.
public struct LunaSkyTrait: UITraitDefinition {
    public static let defaultValue = LunaSky.night
    public static let affectsColorAppearance = true
    public static let name = "Luna sky"
    public static let identifier = "com.luna.designsystem.sky"
}

public extension UITraitCollection {
    var lunaSky: LunaSky { self[LunaSkyTrait.self] }
}

public extension UIMutableTraits {
    var lunaSky: LunaSky {
        get { self[LunaSkyTrait.self] }
        set { self[LunaSkyTrait.self] = newValue }
    }
}
