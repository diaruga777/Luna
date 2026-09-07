//
//  TranscriptionShellWiring.swift
//  Luna
//
//  The transcription runner's half of the app shell: the background lease and
//  the pending card's status line at launch, and a `kick()` at each lifecycle
//  point where new work can have appeared. Only the central Luna app compiles
//  this file — it imports `LunaTranscribe`, which only that target links — so
//  the three sibling apps exclude it by membership exception, as they do
//  `MediaShellWiring.swift` (`claudedocs/plans/transcription-plugins.md` §6).
//

import LunaModels
import LunaStorage
import LunaTranscribe
import UIKit

enum TranscriptionShellWiring {

    @MainActor
    static func install() {
        TranscriptionJobRunner.shared.lease = AppBackgroundLease()
        PendingSaveStatus.provider = TranscriptionPendingStatusProvider()
    }

    // MARK: - Lifecycle

    /// The sweep runs before the first `kick()`: a file a killed run left
    /// behind has no live row and is removed, and a live row's file survives
    /// for the run that resumes it.
    static func appDidLaunch() {
        Task { @MainActor in
            TranscriptionScratchSweep.run(
                directory: SavesStore.shared.transcriptionScratchDirectoryURL,
                store: TranscriptionJobStore.shared)
            TranscriptionJobRunner.shared.kick()
        }
    }

    static func sceneDidForeground() {
        Task { @MainActor in TranscriptionJobRunner.shared.kick() }
    }

    static func savesDidChange() {
        Task { @MainActor in TranscriptionJobRunner.shared.kick() }
    }
}

/// Keeps the process alive for the length of one job through a UIKit
/// background task.
final class AppBackgroundLease: TranscriptionBackgroundLeasing {
    func begin() -> TranscriptionLeaseToken? {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "luna.transcription") {}
        guard identifier != .invalid else { return nil }
        return TranscriptionLeaseToken(rawValue: identifier.rawValue)
    }

    func end(_ token: TranscriptionLeaseToken) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token.rawValue))
    }
}

/// The pending card's status line for a save with a transcription job.
final class TranscriptionPendingStatusProvider: PendingSaveStatusProviding {
    func status(forSaveID id: UUID) -> String? {
        TranscriptionJobStore.shared.status(saveID: id).flatMap(TranscriptionStatusCopy.text)
    }
}
