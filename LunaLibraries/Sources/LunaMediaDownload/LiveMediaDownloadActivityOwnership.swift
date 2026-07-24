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
}
