//
//  AppletStore.swift
//  clipper
//

import Foundation

enum AppletStoreError: Error {
    case writeFailed(Error)
    case readFailed(Error)
    case coordinationFailed(Error)
}

/// Persists applets as a single flat binary plist in the App Group container, so
/// both the main app and the background ingest extension see the same rules and
/// counts. Reads and writes are wrapped in `NSFileCoordinator` because the two
/// processes can mutate the file concurrently — a plain atomic write would let one
/// process clobber the other's increment (lost update). Unlike the photo index and
/// downloaded models (derived, re-creatable, excluded from backup), applets are
/// user-authored data and are intentionally left eligible for backup.
protocol AppletStore: Sendable {
    /// All applets, in creation order (oldest first).
    func list() throws -> [Applet]

    /// Inserts a new applet or replaces an existing one with the same `id`.
    func upsert(_ applet: Applet) throws

    /// Removes the applet with the given id, if present.
    func delete(id: UUID) throws

    /// Records that `assetID` matched the applet. Increments `captureCount` only if
    /// the asset was not already counted. Returns whether this was a new match
    /// (false if the applet is unknown or the asset was already counted).
    @discardableResult
    func recordMatch(appletID: UUID, assetID: String) throws -> Bool
}

final class AppletStoreImpl: AppletStore {

    private let logger: Logger
    private let fileURL: URL

    init(logger: Logger, fileURL: URL? = nil) {
        self.logger = logger
        self.fileURL = fileURL ?? Self.defaultURL()
    }

    func list() throws -> [Applet] {
        try coordinatedRead()
    }

    func upsert(_ applet: Applet) throws {
        try mutate { applets in
            if let index = applets.firstIndex(where: { $0.id == applet.id }) {
                applets[index] = applet
            } else {
                applets.append(applet)
            }
        }
    }

    func delete(id: UUID) throws {
        try mutate { applets in
            applets.removeAll { $0.id == id }
        }
    }

    @discardableResult
    func recordMatch(appletID: UUID, assetID: String) throws -> Bool {
        try mutate { applets in
            guard let index = applets.firstIndex(where: { $0.id == appletID }) else {
                return false
            }
            let (inserted, _) = applets[index].matchedAssetIdentifiers.insert(assetID)
            if inserted {
                applets[index].captureCount += 1
            }
            return inserted
        }
    }

    // MARK: - Coordinated I/O

    /// Reads the current applets under a coordinated read.
    private func coordinatedRead() throws -> [Applet] {
        var coordinationError: NSError?
        var result: Result<[Applet], Error> = .success([])
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            result = Result { try Self.decode(at: url) }
        }
        if let coordinationError { throw AppletStoreError.coordinationFailed(coordinationError) }
        return try result.get()
    }

    /// Performs a read-modify-write under a single coordinated write so the
    /// extension and the app can't lose each other's updates.
    @discardableResult
    private func mutate<T>(_ body: (inout [Applet]) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error> = .failure(AppletStoreError.writeFailed(CocoaError(.fileNoSuchFile)))
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
            result = Result {
                var applets = (try? Self.decode(at: url)) ?? []
                let value = try body(&applets)
                try Self.write(applets, to: url)
                return value
            }
        }
        if let coordinationError { throw AppletStoreError.coordinationFailed(coordinationError) }
        return try result.get()
    }

    private static func decode(at url: URL) throws -> [Applet] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try PropertyListDecoder().decode([Applet].self, from: data)
        } catch {
            throw AppletStoreError.readFailed(error)
        }
    }

    private static func write(_ applets: [Applet], to url: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(applets)
            try data.write(to: url, options: .atomic)
        } catch {
            throw AppletStoreError.writeFailed(error)
        }
    }

    private static func defaultURL() -> URL {
        let directory = AppGroup.containerURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory
            .appendingPathComponent("Applets", isDirectory: true)
            .appendingPathComponent("applets.plist", isDirectory: false)
    }
}
