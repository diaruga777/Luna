//
//  PluginTranscriptionSeams.swift
//  LunaModels
//

import Foundation

/// What a plugin answered when the runner asked it to re-resolve a stale
/// transcription source.
public enum TranscriptionReresolution: Equatable {
    /// Fresh URLs for the same recording. Replaces the stored request.
    case request(TranscriptionRequest)
    /// The plugin now has the text itself (captions appeared). The runner
    /// persists it without a download.
    case article(ArticleContent)
}

/// Re-runs one plugin's `ingest` with reason `reresolve` for a save whose
/// recording URL expired or was refused (`claudedocs/plans/transcription-plugins.md`
/// §5.3). The one production conformer lives in LunaPluginIngest and walks the
/// same plugin that produced the save.
public protocol TranscriptionReresolving: AnyObject {
    func reresolve(
        sourceURL: URL, pluginID: String, saveID: UUID
    ) async -> TranscriptionReresolution?
}

/// The re-resolution seam, held at the bottom of the stack for the same reason
/// `PluginMediaSeams` is: the runner (LunaTranscribe) cannot import the plugin
/// tier, and the plugin tier cannot import the runner.
/// `PluginPlatformComposition.install()` is the only writer.
public enum PluginTranscriptionSeams {
    public static var reresolver: (any TranscriptionReresolving)?
}
