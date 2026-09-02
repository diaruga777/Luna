//
//  PluginIngestStaging.swift
//  LunaIngest
//

import LunaFetch
import Foundation

/// What the plugin walk decided for one URL.
///
/// `passed` is the ordinary answer: no plugin matched the host, every matched
/// plugin declined, or a plugin broke. The pipeline then runs the Swift
/// `Classifier`, which is the floor under every plugin.
public enum PluginIngestVerdict {
    /// Nothing was claimed. Continue with `Classifier.classify`.
    case passed
    /// A plugin produced a Model and its kind module adopted it. `pluginID` is
    /// the owner the save is stamped with.
    case outcome(Outcome, pluginID: String)
    /// The plugin asked for a browser this process cannot present. The save is
    /// stored locked and finished in the app later. The request row itself is
    /// written by the browser bridge, which has the save id; this carries only
    /// the owner so the store write can route back to it.
    case locked(pluginID: String)
}

/// The plugin classify + ingest walk, run before the Swift classifier.
///
/// `LunaPluginIngest.PluginIngestStage` is the witness. Only the central Luna
/// app and its share/action extensions install one; `IngestPipeline.pluginStage`
/// stays nil in the three sibling apps, so they carry no plugin behaviour at
/// all. Governing plan: claudedocs/plans/plugin-platform.md §7.4.
public protocol PluginIngestStaging {
    /// Runs the walk for the already-unwrapped `input`. `fetcher` is the
    /// pipeline's own fetcher, so a stage that needs the page reuses it rather
    /// than opening a second one.
    func run(_ input: IngestInput, fetcher: HTMLFetching) async -> PluginIngestVerdict
}

public extension IngestPipeline {
    /// The installed walk, or nil where no plugin platform runs.
    /// `PluginPlatformComposition.install()` is the only writer.
    static var pluginStage: PluginIngestStaging?
}
