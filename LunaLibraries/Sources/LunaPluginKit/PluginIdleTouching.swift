//
//  PluginIdleTouching.swift
//  LunaPluginKit
//

import Foundation

/// Reports that a plugin's hook is still doing useful work.
///
/// The pipeline's idle watchdog is a task-local, and plugin JavaScript runs on
/// the runtime's own queue where that local is not visible. So the ingest stage
/// installs a witness holding the watchdog's heartbeat, and every bridge call
/// touches it — a 30-second read of a slow server keeps the save alive, and a
/// plugin that stops asking for anything does not.
public protocol PluginIdleTouching: AnyObject {
    /// `pluginID` names whose in-flight hooks the touch keeps alive. Two hooks
    /// of one plugin can overlap, and a bridge callback cannot tell which of
    /// them it belongs to, so both are touched.
    func touchIdle(pluginID: String)
}
