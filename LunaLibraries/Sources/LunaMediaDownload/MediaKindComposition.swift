//
//  MediaKindComposition.swift
//  LunaMediaDownload
//

import LunaModels
import LunaShareSurface
import Foundation

/// THE single definition of what registering the **media kind** (social / video /
/// audio links) means, for every surface of every media-handling app.
///
/// One call per root, so a surface cannot be wired half-way. See
/// `ArticleKindComposition` for why the per-surface lists were replaced.
public enum MediaKindComposition {

    /// Registers every media-kind entry. Media needs NO pipeline processor: it is
    /// classified from the URL alone (`PlatformRecognizer` / `DirectMediaURL`), so
    /// `IngestKindProcessors` has no media slot and only the extension presenter
    /// registers here. That asymmetry is exactly the kind of per-kind detail worth
    /// stating once, in one place, instead of re-deriving it at each root.
    ///
    /// Not included: `IngestorKindHandlers.media`, the app-shell persistence
    /// handler, which is built from app-shell types and stays in `KindWiring+*`.
    @MainActor
    public static func install() {
        ShareKindPresenters.media = ExtensionMediaPresenter()
        // The plugin platform's media half. Harmless where no plugin runs: the
        // walk that reads it only exists in the central app's processes.
        PluginModelAdopters.media = MediaModelAdopter()
    }
}
