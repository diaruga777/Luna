//
//  RabbitHoleStackStore.swift
//  Luna
//
//  Forked, experimental "RabbitHole" reader — see RabbitHoleReaderViewController.
//

import LunaAppConfig
import LunaStorage
import LunaModels
import Foundation

/// Persists each save's RabbitHole breadcrumb trail (the stack of layers the user dove
/// into) as a small JSON file in the App Group container, keyed by the root reading-list
/// item id: `RabbitHole/<rootID>.json`.
///
/// Deliberately separate from `ReadingListStore`/`ReadingListItem`: this is transient,
/// experiment-only session state, so it never touches the cross-process saves database
/// nor bloats every list read. Only the main app reads/writes it, so no cross-process
/// coordination is needed (plain atomic writes).
public final class RabbitHoleStackStore {
    public static let shared = RabbitHoleStackStore()

    public static let appGroupID = AppConfig.appGroupID

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?

    public init(containerURL: URL? = nil) { self.overrideContainerURL = containerURL }

    private var containerURL: URL {
        if let overrideContainerURL { return overrideContainerURL }
        return AppConfig.sharedContainerURL(fileManager) ?? fileManager.temporaryDirectory
    }

    private var directory: URL {
        let dir = containerURL.appendingPathComponent("RabbitHole", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupPolicy.includeInBackups(dir)
        return dir
    }

    private func fileURL(forRootID id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Load a saved trail; nil when none exists (or it can't be decoded).
    public func load(forRootID id: UUID) -> RabbitHoleStack? {
        guard let data = try? Data(contentsOf: fileURL(forRootID: id)) else { return nil }
        return try? JSONDecoder().decode(RabbitHoleStack.self, from: data)
    }

    /// Save (or, for a single root-only stack, clear) a trail. A trail that has been
    /// collapsed back to just the root is removed so a stale deep trail can't resurface.
    public func save(_ stack: RabbitHoleStack, forRootID id: UUID) {
        guard stack.layers.count > 1 else { clear(forRootID: id); return }
        guard let data = try? JSONEncoder().encode(stack) else { return }
        let url = fileURL(forRootID: id)
        try? data.write(to: url, options: .atomic)
        BackupPolicy.includeInBackups(url)
    }

    public func clear(forRootID id: UUID) {
        try? fileManager.removeItem(at: fileURL(forRootID: id))
    }
}
