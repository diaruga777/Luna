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
            case .system: return L10n.string("Settings_appearance_system")
            case .light: return L10n.string("Settings_appearance_light")
            case .dark: return L10n.string("Settings_appearance_dark")
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
        followSystemStyle(of: viewController)
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
    ///
    /// Held WEAKLY, so an entry lasts exactly as long as the scene it names. An
    /// identifier that outlived its scene would match the next scene the allocator
    /// puts at that address, and that scene would be taken for one already watched
    /// — its windows would then never follow the device style in `.system` mode.
    nonisolated(unsafe) private static let observedScenes =
        NSHashTable<UIWindowScene>.weakObjects()

    /// In `.system` mode the sky has to follow the device, which the pinned window
    /// can no longer tell us about — so watch the scene instead. One registration
    /// per scene: `apply(to:)` runs again for every window each time the preference
    /// changes.
    @MainActor
    private static func followSystemStyle(of window: UIWindow) {
        guard let scene = window.windowScene, !observedScenes.contains(scene) else { return }
        observedScenes.add(scene)
        scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (scene: UIWindowScene, _) in
            let resolved = sky(systemStyle: scene.traitCollection.userInterfaceStyle)
            for window in scene.windows {
                window.traitOverrides.lunaSky = resolved
            }
        }
    }

    /// View controllers, similarly held WEAKLY: an extension/App Clip screen that
    /// deallocates should not leave a dangling registration behind.
    nonisolated(unsafe) private static let observedViewControllers =
        NSHashTable<UIViewController>.weakObjects()

    /// A share/action extension or App Clip pins the VIEW CONTROLLER, not a window
    /// it owns, so — same problem `followSystemStyle(of window:)` solves one level
    /// up — its own resolved style can no longer report a device appearance flip
    /// either. The window it's presented in (the host app's, for an extension; the
    /// clip's own, for a Clip) carries no override of ours, so watch that instead.
    /// `viewDidLoad` runs before this screen is inserted into that window (an
    /// extension host attaches it only after presenting the principal view
    /// controller returns), so a still-nil window is retried a few run-loop turns
    /// rather than given up on — by the time this screen is actually on screen for
    /// the user to see, its window must exist.
    @MainActor
    private static func followSystemStyle(of viewController: UIViewController, attemptsRemaining: Int = 5) {
        guard !observedViewControllers.contains(viewController) else { return }
        guard let window = viewController.view.window else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.async { [weak viewController] in
                guard let viewController else { return }
                followSystemStyle(of: viewController, attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }
        observedViewControllers.add(viewController)
        window.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak viewController] (window: UIWindow, _) in
            guard let viewController else { return }
            viewController.traitOverrides.lunaSky = sky(systemStyle: window.traitCollection.userInterfaceStyle)
        }
    }
}
