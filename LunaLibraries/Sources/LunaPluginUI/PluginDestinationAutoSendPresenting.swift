//
//  PluginDestinationAutoSendPresenting.swift
//  LunaPluginUI
//

import UIKit

/// Opens the per-capture-source auto-send screen for one destination.
///
/// That screen is app-shell code (`Luna/Settings/AutoSendBySourceScreen.swift`)
/// and this module sits below it, so central Luna installs the witness. Where
/// none is installed the plugin's detail screen simply offers no row: an app
/// with no auto-send screen must not advertise one.
@MainActor
public protocol PluginDestinationAutoSendPresenting {
    func presentAutoSend(
        destinationID: String, displayName: String, from presenter: UIViewController)
}

/// Where the app installs that witness.
@MainActor
public enum PluginDestinationAutoSend {
    public static var presenter: (any PluginDestinationAutoSendPresenting)?
}
