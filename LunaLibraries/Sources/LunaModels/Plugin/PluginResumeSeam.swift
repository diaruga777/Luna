//
//  PluginResumeSeam.swift
//  LunaModels
//

import Foundation

/// Re-runs the pipeline for a save a plugin locked, once its browser step has
/// an answer (`claudedocs/plans/plugin-platform.md` §8.3).
///
/// The run keeps the save's id, so the plugin's Model replaces the locked
/// placeholder rather than adding a second row.
public protocol PluginLockedSaveResuming: AnyObject {
    func resumePluginLockedSave(id: UUID) async
}

/// The resume seam, held at the bottom of the stack for the same reason
/// `PluginPriceSeams` is: LunaPluginUI presents the browser step and cannot
/// import LunaSaves. The app shell is the only writer.
public enum PluginResumeSeams {
    public static var resumer: (any PluginLockedSaveResuming)?
}

public extension SavedItem {
    /// A save parked in the archive lock BY A PLUGIN, waiting for the browser
    /// step only the app can show. The archive unlock parks a save in the same
    /// state and leaves `pluginID` nil, so the owner is what tells the two
    /// flows apart at every card and both extensions.
    var isPluginLocked: Bool {
        state == .needsCaptcha && pluginID != nil
    }
}
