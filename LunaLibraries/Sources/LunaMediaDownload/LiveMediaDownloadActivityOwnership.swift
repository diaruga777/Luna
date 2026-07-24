//
//  LiveMediaDownloadActivityOwnership.swift
//  LunaMediaDownload
//

import Foundation

extension LiveMediaDownloadManager {

    /// Set while an App Intent runs under the SYSTEM's extended-runtime progress
    /// UI (`LongRunningIntent`, iOS 27+): Luna's own download Live Activity is
    /// suppressed for the duration, so the two don't stack and the system's — fed
    /// by the intent's `progress` — is the single source of truth.
    ///
    /// Bound ONLY around an intent's awaited download. A transfer that outlives
    /// the intent keeps Luna's activity, because the system's progress UI ends
    /// when the intent returns; suppressing ours there would leave a background
    /// download with no UI at all.
    ///
    /// A task local rather than a flag: it scopes to exactly the intent's task
    /// tree, so a concurrent in-app save still gets its own Live Activity, and
    /// there is no global state to forget to clear.
    @TaskLocal
    public static var systemProvidesProgressUI: Bool = false

    /// The system's intent progress UI has gone away while a transfer is still
    /// running — the intent was cancelled from that UI, or the system reclaimed
    /// its runtime. Start Luna's own Live Activity for the job so a download that
    /// keeps going doesn't keep going invisibly.
    ///
    /// Silent (no start alert): the download isn't new, it's changing hands. Must
    /// be called OUTSIDE the `systemProvidesProgressUI` binding, or the
    /// suppression it exists to undo swallows it.
    public func resumeOwnProgressUI(forSourceURLString urlString: String) async {
        guard !Self.systemProvidesProgressUI,
              let job = jobAwaitingProgressUI(forSourceURLString: urlString)
        else { return }
        await startActivity(for: job, announce: false)
    }
}
