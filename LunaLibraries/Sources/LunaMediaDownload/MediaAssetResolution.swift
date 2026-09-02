//
//  MediaAssetResolution.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels

/// Which resolver a media-handling app turns a post URL into assets with.
///
/// Two apps download media and they answer this differently: central Luna runs
/// the bundled media plugins, and the Downloader runs the Swift resolvers in
/// LunaMediaResolve. The app shell they SHARE (`MediaShellWiring`) must not have
/// to know which of the two it is compiled into, so the choice lives here, in
/// the module that owns both halves.
///
/// `PluginPlatformComposition.install()` fills `PluginMediaSeams.resolver` in
/// the central app's three processes, and nowhere else. Governing plan:
/// `claudedocs/plans/plugin-platform.md` §7.6.
public enum MediaAssetResolution {

    /// The plugin walk where a plugin platform runs, and the Swift resolver
    /// where none does.
    public static var resolver: any SocialMediaResolving {
        PluginMediaSeams.resolver ?? SocialMediaResolver()
    }
}
