//
//  AppearanceSettings.swift
//  Luna
//

import LunaAppConfig
import UIKit

/// App-wide appearance preferences, persisted in the App Group so all three apps and
/// their extensions render with the same interface style and motion behavior.
public enum AppearanceSettings {
    private static var defaults: UserDefaults { UserDefaults(suiteName: ReaderSettings.appGroupID) ?? .standard }

    private static let interfaceStyleKey = "appearanceInterfaceStyle"
    private static let animatedTransitionsKey = "animatedTransitionsEnabled"
    private static let lunarEclipseReaderTransitionKey = "lunarEclipseReaderTransitionEnabled"

    /// The interface style the app forces regardless of the device setting.
    public enum InterfaceStyle: String, CaseIterable {
        case system, light, dark

        public var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        public var uiStyle: UIUserInterfaceStyle {
            switch self {
            case .system: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    /// The interface style override applied to every window. Defaults to `.system`.
    public static var interfaceStyle: InterfaceStyle {
        get { InterfaceStyle(rawValue: defaults.string(forKey: interfaceStyleKey) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: interfaceStyleKey) }
    }

    /// Whether animated (Dot Matrix pixel-wipe) transitions play. On by default; when
    /// off, view-controller transitions, modals, and list changes use the stock UIKit
    /// animations.
    public static var animatedTransitionsEnabled: Bool {
        get { (defaults.object(forKey: animatedTransitionsKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: animatedTransitionsKey) }
    }

    /// An opt-in, Reader-only alternative to the Dot Matrix navigation wipe. It is
    /// deliberately off by default while the motion is being evaluated.
    public static var lunarEclipseReaderTransitionEnabled: Bool {
        get { (defaults.object(forKey: lunarEclipseReaderTransitionKey) as? Bool) ?? false }
        set { defaults.set(newValue, forKey: lunarEclipseReaderTransitionKey) }
    }

    /// Applies the current `interfaceStyle` override to a window. Call at every
    /// window-creation site so the whole app (and its transition cover windows)
    /// honor the chosen theme.
    public static func apply(to window: UIWindow) {
        window.overrideUserInterfaceStyle = interfaceStyle.uiStyle
    }
}
