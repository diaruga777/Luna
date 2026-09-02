//
//  LunaBundledPlugins.swift
//  LunaBundledPlugins
//

import Foundation

/// The resource bundle holding the plugins Luna ships with.
///
/// `BundledPluginCatalog` (LunaPluginKit) reads the `.js` files from the
/// `Plugins` subdirectory. The bundle is exposed rather than the files
/// themselves so the catalog stays in the module that owns plugin identity, and
/// this target keeps no code of its own.
public enum LunaBundledPluginsBundle {
    public static let bundle = Bundle.module
    /// The subdirectory the plugins are copied into, for
    /// `Bundle.url(forResource:withExtension:subdirectory:)`.
    public static let pluginsSubdirectory = "Plugins"
}
