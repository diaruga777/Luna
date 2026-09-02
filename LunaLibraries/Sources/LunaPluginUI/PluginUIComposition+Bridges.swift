//
//  PluginUIComposition+Bridges.swift
//  LunaPluginUI
//

import LunaModels
import LunaPluginIngest
import LunaPluginKit
import LunaPluginRuntime
import LunaSavesUI
import UIKit

/// Presents a plugin's browser step over whatever the app has on screen.
///
/// It resolves the presenter at the moment the step is asked for, not at
/// install: a plugin's ingest can start under a card deck and finish under a
/// settings screen.
@MainActor
public final class ModalPluginBrowserPresenter: PluginBrowserPresenting {
    private let modal: PluginBrowserModalPresentation

    public init(pageMaker: (any PluginBrowserPageMaking)? = nil) {
        self.modal = PluginBrowserModalPresentation(pageMaker: pageMaker)
    }

    public func presentBrowserStep(
        _ request: PluginBrowserRequest, pluginID: String
    ) async -> PluginBrowserResult? {
        guard !modal.isPresented, let presenter = PluginTopPresenter.current() else { return nil }
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<PluginBrowserResult?, Never>) in
            modal.present(request, from: presenter) { result in
                continuation.resume(returning: result)
            }
        }
    }
}

/// The frontmost view controller of the foreground scene's key window.
public enum PluginTopPresenter {

    @MainActor
    public static func window() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
    }

    @MainActor
    public static func current() -> UIViewController? {
        var top = window()?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

public extension PluginUIComposition {

    /// The bridges this module owns, for the process asking
    /// (`claudedocs/plans/plugin-platform.md` §6.10–§6.12).
    ///
    /// All three are handed over in every process. Each refuses on its own
    /// terms rather than being absent, so a plugin's declared capability stays
    /// visible and its rejection carries a code the plugin can branch on: the
    /// browser bridge defers in an extension, `luna.settings.set` and every
    /// `luna.ui` call answer `unavailable-here` there.
    @MainActor
    static func bridges(
        processKind: PluginProcessKind, scheduler: PluginCallbackScheduling
    ) -> [any PluginCapabilityInstalling] {
        [
            PluginBrowserBridge(
                processKind: processKind, scheduler: scheduler,
                presenter: processKind == .app ? browserPresenter : nil),
            PluginSettingsBridge(processKind: processKind, scheduler: scheduler),
            PluginUIBridge(processKind: processKind, scheduler: scheduler),
        ]
    }

    /// The app's browser modal. One instance, because one browser step runs at
    /// a time.
    @MainActor private static let browserPresenter = ModalPluginBrowserPresenter()

    /// Installs the app-only witnesses: the `luna.ui` presenter and the unlock
    /// route a locked card's tap takes.
    @MainActor
    static func installAppWitnesses(_ presenter: PluginUIPresenting? = nil) {
        install(presenter)
        PluginLockedSaves.presenter = PluginUnlockFlow.shared
    }
}
