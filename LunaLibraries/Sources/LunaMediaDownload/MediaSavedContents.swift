//
//  MediaSavedContents.swift
//  LunaMediaDownload
//

import Foundation

/// Everything the media kind may have written for one link, in one place.
///
/// Two callers discard it: the extension surface, when the user asks for the
/// media again, and the platform ingestor, when a recovery file replaces the
/// content of a save that already downloaded the wrong file
/// (`claudedocs/llm-handoff.md`). Both must drop the same three things, or the
/// download gate answers "already downloaded" and the wrong file stays.
@MainActor
public enum MediaSavedContents {

    /// Drops the durable library row (whose own delete removes its files), any
    /// in-flight preload, and the already-downloaded marker. The save row
    /// itself is kind-neutral and belongs to the caller.
    public static func discard(forURLString urlString: String) {
        MediaPreloadCache.shared.discard(urlString: urlString)
        if let item = SavedMediaStore.shared.existingDownloadedItem(forURLString: urlString) {
            SavedMediaStore.shared.delete(item)
        }
        AutoDownloadSettings.unmarkDownloaded(urlString)
    }
}
