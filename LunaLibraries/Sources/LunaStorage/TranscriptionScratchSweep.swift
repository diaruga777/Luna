//
//  TranscriptionScratchSweep.swift
//  LunaStorage
//

import Foundation

/// Unlinks every file in the transcription scratch directory that no live job
/// names (`claudedocs/plans/transcription-plugins.md` §4.3).
///
/// A recording is downloaded to the scratch directory and deleted by the runner
/// when its job ends. A process killed in between leaves the file; this runs at
/// launch and removes it, so nothing survives a job that is `done` or `failed`.
public enum TranscriptionScratchSweep {

    /// Removes the orphans and returns their names. A missing directory is an
    /// empty sweep.
    @discardableResult
    public static func run(
        directory: URL, store: TranscriptionJobStore, fileManager: FileManager = .default
    ) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let live = store.liveScratchPaths()
        var removed: [String] = []
        for name in names where !live.contains(name) {
            let url = directory.appendingPathComponent(name)
            if (try? fileManager.removeItem(at: url)) != nil { removed.append(name) }
        }
        return removed
    }
}
