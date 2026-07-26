//
//  AppearanceSettings.swift
//  Luna
//

import LunaAppConfig
import UIKit
import LunaModels

/// App-wide appearance preferences, persisted in the App Group so all three apps and
/// their extensions render with the same interface style.
public enum AppearanceSettings {
    private static var defaults: UserDefaults { UserDefaults(suiteName: ReaderSettings.appGroupID) ?? .standard }

    private static let interfaceStyleKey = "appearanceInterfaceStyle"

    /// The interface style the app forces regardless of the device setting.
    public enum InterfaceStyle: String, CaseIterable {
        case system, light, dark

        public var displayName: String {
            switch self {
            case .system: return L10n.string("System")
            case .light: return L10n.string("Light")
            case .dark: return L10n.string("Dark")
            }
        }
    }

    /// The interface style override applied to every window. Defaults to `.system`.
    public static var interfaceStyle: InterfaceStyle {
        get { InterfaceStyle(rawValue: defaults.string(forKey: interfaceStyleKey) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: interfaceStyleKey) }
    }

    /// Applies the current `interfaceStyle` to a window. Call at every
    /// window-creation site so the whole app honors the chosen theme.
    ///
    /// The chosen style does NOT become the window's `userInterfaceStyle`: both
    /// Luna appearances are night, so the style stays pinned to `.dark` (keeping
    /// UIKit's own glass, blur, alerts and keyboards dark) and the choice travels
    /// on `LunaSkyTrait` instead. See `LunaSky`.
    @MainActor
    public static func apply(to window: UIWindow) {
        LunaColors.installGlobalAppearance()
        window.overrideUserInterfaceStyle = .dark
        window.traitOverrides.lunaSky = sky(systemStyle: systemStyle(for: window))
        window.backgroundColor = LunaColors.background
        followSystemStyle(of: window)
    }

    /// Pins an extension's root view controller the same way. Extensions get their
    /// window from the host app, so they can't configure it themselves.
    @MainActor
    public static func apply(to viewController: UIViewController) {
        LunaColors.installGlobalAppearance()
        // Read the inherited style BEFORE pinning it, or `.system` can only ever
        // resolve to the style we just forced.
        let resolved = sky(systemStyle: viewController.traitCollection.userInterfaceStyle)
        viewController.overrideUserInterfaceStyle = .dark
        viewController.traitOverrides.lunaSky = resolved
    }

    /// Which sky the current preference resolves to.
    public static func sky(systemStyle: UIUserInterfaceStyle) -> LunaSky {
        switch interfaceStyle {
        case .light: return .predawn
        case .dark: return .night
        case .system: return systemStyle == .light ? .predawn : .night
        }
    }

    /// The device's style, read from the scene rather than the window — the
    /// window's own style is pinned, so it can no longer report it.
    private static func systemStyle(for window: UIWindow) -> UIUserInterfaceStyle {
        window.windowScene?.traitCollection.userInterfaceStyle
            ?? UITraitCollection.current.userInterfaceStyle
    }

    /// Scenes whose system-style changes are already being watched.
    nonisolated(unsafe) private static var observedScenes: Set<ObjectIdentifier> = []

    /// In `.system` mode the sky has to follow the device, which the pinned window
    /// can no longer tell us about — so watch the scene instead.
    @MainActor
    private static func followSystemStyle(of window: UIWindow) {
        guard let scene = window.windowScene,
              observedScenes.insert(ObjectIdentifier(scene)).inserted
        else { return }
        scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (scene: UIWindowScene, _) in
            let resolved = sky(systemStyle: scene.traitCollection.userInterfaceStyle)
            for window in scene.windows {
                window.traitOverrides.lunaSky = resolved
            }
        }
    }
}
