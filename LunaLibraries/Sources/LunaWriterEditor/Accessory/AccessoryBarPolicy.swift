//
//  AccessoryBarPolicy.swift
//  LunaWriterEditor
//

import CoreGraphics
import LunaDesignSystem

/// Whether the Markdown accessory bar earns its screen space right now.
///
/// `containerWidth` is the editor's own column width, not the screen's —
/// Split View, Slide Over and a Mac window all narrow it independent of the
/// device.
public protocol AccessoryBarPolicy {
    func shouldShowAccessoryBar(hasHardwareKeyboard: Bool, containerWidth: CGFloat) -> Bool
}

/// iOS's rule: on an iPad-width column, a hardware keyboard already reaches
/// every command the bar offers, so the bar goes. On a phone-width column the
/// bar is often the only way to a command, so it stays regardless.
public struct DefaultAccessoryBarPolicy: AccessoryBarPolicy {
    public init() {}

    public func shouldShowAccessoryBar(hasHardwareKeyboard: Bool, containerWidth: CGFloat) -> Bool {
        !(hasHardwareKeyboard && containerWidth >= LunaLayout.wideThreshold)
    }
}

/// The Mac root's rule: a physical keyboard is guaranteed, so the bar never
/// shows.
public struct MacAccessoryBarPolicy: AccessoryBarPolicy {
    public init() {}

    public func shouldShowAccessoryBar(hasHardwareKeyboard: Bool, containerWidth: CGFloat) -> Bool {
        false
    }
}
