//
//  ResolvedMediaStores.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig
import LunaModels

/// What one page's media resolved to: the post URL the user was on, the assets
/// `SocialMediaResolver` produced for it, and the page title to name a download
/// with. The Safari extension's native handler produces these; the app consumes
/// them (`claudedocs/safari-extension.md`).
public struct ResolvedMediaRecord: Codable, Equatable {
    public let sourceURLString: String
    public let title: String?
    public let assets: [MediaAsset]
    public let dateWritten: Date
    /// The Safari Download tap asks the containing app to hand focus back to
    /// this page. Keeping that intent beside the queued assets closes the cold-
    /// launch/foreground race where lifecycle recovery drains the queue before
    /// `SceneDelegate` receives the custom URL carrying `ret=safari`.
    /// Optional so records written by an older app continue to decode.
    public let returnToSourceUntil: Date?

    public init(
        sourceURLString: String, title: String?, assets: [MediaAsset],
        dateWritten: Date, returnToSourceUntil: Date? = nil
    ) {
        self.sourceURLString = sourceURLString
        self.title = title
        self.assets = assets
        self.dateWritten = dateWritten
        self.returnToSourceUntil = returnToSourceUntil
    }
}

/// The Safari extension's own scratch memory of what it last resolved.
///
/// It exists so the page's JavaScript never has to HOLD a resolved asset: the
/// overlay is told only the one URL it can play, and its Download button says
/// "queue what you resolved for this page" rather than handing a `[MediaAsset]`
/// back through native messaging. That keeps every asset field — the separate
/// audio stream, the DASH manifest, the byte estimate — inside Swift, where it
/// was produced, instead of round-tripping through a JS object that would have
/// to mirror the Codable shape faithfully to survive.
///
/// Short-lived and small, because it is a step in one user interaction: an
/// entry the user never acts on is scratch, and CDN URLs expire anyway (a
/// googlevideo URL is IP-bound and dies within hours).
public final class ResolvedMediaCache {
    public static let shared = ResolvedMediaCache()

    /// Long enough to watch the video and then decide to download it.
    public static let lifetime: TimeInterval = 60 * 60
    /// Enough for a browsing session's worth of pages; the oldest fall off.
    public static let capacity = 12

    private static let key = "safari.resolvedMediaCache"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let lock = NSLock()

    public init(defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults ?? UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
        self.now = now
    }

    /// Records what `record.sourceURLString` resolved to, replacing any earlier
    /// entry for the same page and dropping expired/overflowing ones.
    public func store(_ record: ResolvedMediaRecord) {
        lock.lock(); defer { lock.unlock() }
        var current = loadLocked().filter { $0.sourceURLString != record.sourceURLString }
        current.append(record)
        saveLocked(current.suffix(Self.capacity).map { $0 })
    }

    /// The non-expired record for `urlString`, or nil. Non-destructive: the
    /// overlay may resolve once and download later.
    public func record(forURLString urlString: String) -> ResolvedMediaRecord? {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().last { $0.sourceURLString == urlString }
    }

    private func loadLocked() -> [ResolvedMediaRecord] {
        guard let data = defaults.data(forKey: Self.key),
              let all = try? JSONDecoder().decode([ResolvedMediaRecord].self, from: data)
        else { return [] }
        return all.filter { now().timeIntervalSince($0.dateWritten) < Self.lifetime }
    }

    private func saveLocked(_ records: [ResolvedMediaRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// App-Group-backed queue of media the user asked for from Safari's in-page
/// player, already resolved to direct asset URLs.
///
/// Modeled on `PendingRescueRequestStore`: an ARRAY (several overlays can queue
/// before the app opens), take-semantics, and the same 3-day lifetime — a tap
/// whose app launch the user abandons until the next morning must still land.
/// The two media apps drain it from their `KindWiring`s, on launch/foreground
/// and on the `<scheme>://resolvedmedia` deep link.
public final class PendingResolvedMediaStore {
    public static let shared = PendingResolvedMediaStore()

    public static let lifetime: TimeInterval = 3 * 24 * 60 * 60

    private static let key = "media.pendingResolvedDownloads"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let lock = NSLock()

    public init(defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults ?? UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
        self.now = now
    }

    /// Queues a download, replacing any existing one for the same page (a second
    /// tap re-resolves rather than downloading twice). Drops expired entries in
    /// passing. Ignores an assetless record — there would be nothing to download.
    public func append(_ record: ResolvedMediaRecord) {
        guard !record.assets.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var current = loadLocked().filter { $0.sourceURLString != record.sourceURLString }
        current.append(record)
        saveLocked(current)
    }

    /// One-shot: returns all non-expired queued downloads and clears the queue.
    public func takeAll() -> [ResolvedMediaRecord] {
        lock.lock(); defer { lock.unlock() }
        let fresh = loadLocked()
        defaults.removeObject(forKey: Self.key)
        return fresh
    }

    /// Non-destructive peek (for diagnostics / tests).
    public func peek() -> [ResolvedMediaRecord] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> [ResolvedMediaRecord] {
        guard let data = defaults.data(forKey: Self.key),
              let all = try? JSONDecoder().decode([ResolvedMediaRecord].self, from: data)
        else { return [] }
        return all.filter { now().timeIntervalSince($0.dateWritten) < Self.lifetime }
    }

    private func saveLocked(_ records: [ResolvedMediaRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
