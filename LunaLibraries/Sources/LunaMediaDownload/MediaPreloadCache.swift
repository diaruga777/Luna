//
//  MediaPreloadCache.swift
//  LunaMediaDownload
//

import Foundation

/// One in-flight (or finished) media download per source URL, started before any
/// screen asked for it.
///
/// The onboarding save lesson knows its link the instant the user taps into the
/// conversation, but does not mount the saved-media screen until its sheet is
/// sliding up a second or two later. Without this, those seconds were dead and
/// the fetch then ran in full while the user watched a progress bar; with it the
/// wait overlaps the animation it was always going to be hidden behind.
///
/// Deliberately a CACHE of tasks, not of files: joining an in-flight download is
/// the whole point (a demo replay must not start a second one), and a Task is the
/// only handle that can be awaited from both the preload and the screen.
@MainActor
public final class MediaPreloadCache {

    public static let shared = MediaPreloadCache()

    private var tasks: [String: Task<DownloadedMedia, Error>] = [:]
    /// The last fraction each preload reported, so a screen that joins one
    /// mid-flight can put its bar where the transfer actually is instead of
    /// starting it over at zero.
    private var progress: [String: Double] = [:]
    private var observers: [String: (Double) -> Void] = [:]
    private let downloadService: MediaDownloadService

    public init(downloadService: MediaDownloadService = MediaDownloadService()) {
        self.downloadService = downloadService
    }

    /// Starts the download for `urlString` unless one is already in flight or
    /// finished. Idempotent, so a repeated lesson entry costs nothing.
    public func preload(urlString: String) {
        guard tasks[urlString] == nil,
              let url = URL(string: urlString),
              MediaDownloadablePlatform.supports(urlString)
        else { return }
        let service = downloadService
        tasks[urlString] = Task { [weak self] in
            try await service.downloadFirstMediaToFile(from: url) { fraction in
                Task { @MainActor in
                    self?.report(fraction, for: urlString)
                }
            }
        }
    }

    /// Follows a preload's progress. The handler fires immediately with whatever
    /// the transfer has already reported, so joining late is not a jump from zero.
    public func observeProgress(
        urlString: String, _ handler: @escaping (Double) -> Void
    ) {
        observers[urlString] = handler
        if let fraction = progress[urlString] { handler(fraction) }
    }

    private func report(_ fraction: Double, for urlString: String) {
        progress[urlString] = fraction
        observers[urlString]?(fraction)
    }

    /// The preloaded download for `urlString`, or nil when nothing was started.
    /// The caller awaits it exactly as it would await its own fetch — already
    /// finished simply means it returns immediately.
    public func take(urlString: String) -> Task<DownloadedMedia, Error>? {
        tasks[urlString]
    }

    /// Drops the entry, cancelling it if it has not finished. The file a FINISHED
    /// task produced is not deleted here: whoever consumed it owns it (the
    /// onboarding session retains it across demo replays), and a temp-directory
    /// purge at launch is the backstop for one nobody claimed.
    public func discard(urlString: String) {
        progress.removeValue(forKey: urlString)
        observers.removeValue(forKey: urlString)
        tasks.removeValue(forKey: urlString)?.cancel()
    }
}
