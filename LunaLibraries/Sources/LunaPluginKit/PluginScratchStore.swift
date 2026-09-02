//
//  PluginScratchStore.swift
//  LunaPluginKit
//

import Foundation

/// One file a plugin wrote or a fetch saved. The plugin holds the descriptor;
/// the bytes stay on disk.
public struct PluginFileDescriptor: Equatable, Codable, Sendable {
    public let id: String
    public let name: String
    public let size: Int
    public let mime: String?

    public init(id: String, name: String, size: Int, mime: String?) {
        self.id = id
        self.name = name
        self.size = size
        self.mime = mime
    }
}

/// Writes bytes into a scratch directory. `luna.fetch` with `as: "file"` uses
/// it, so the fetch service can hand back a file without knowing where the
/// plugin tier keeps one.
public protocol PluginFileWriting: AnyObject {
    func writeFile(
        _ data: Data, suggestedName: String, mime: String?, pluginID: String, generation: String
    ) throws -> PluginFileDescriptor
}

/// Resolves a handle a plugin passed back to the file it names.
public protocol PluginFileReading: AnyObject {
    func fileURL(for descriptor: PluginFileDescriptor) -> URL?
}

/// Opens and closes a plugin's scratch generation.
///
/// A generation is one directory shared by everything in flight for one plugin:
/// the runtime holds one for the length of every hook call, and the export
/// stage holds one across the input file, the hook and the share. It is reaped
/// when the last holder lets go, so a nested call (`onBluetooth` → `export`)
/// cannot delete the outer call's files.
public protocol PluginScratchGenerating: AnyObject {
    /// Joins the plugin's open generation, or opens one, and counts a holder.
    func openScratchGeneration(pluginID: String) -> String
    /// Releases one holder. The generation's directory is reaped when the last
    /// one goes.
    func closeScratchGeneration(pluginID: String)
    /// The generation a bridge writes into now.
    func currentScratchGeneration(pluginID: String) -> String
    /// True while something holds a generation open for this plugin.
    func hasOpenScratchGeneration(pluginID: String) -> Bool
    /// Drops every directory this plugin ever kept. A load calls it, so a
    /// killed process's leftovers go before the new context serves a handle.
    func reapAll(pluginID: String)
}

/// The per-generation scratch directories under
/// `<AppGroup>/Plugins/scratch/<pluginId>/<generation>/`.
///
/// One instance serves every plugin in the process, so a `PluginFileDescriptor`
/// handed to any of them resolves through the same id-to-file map. The
/// directory path carries the plugin id, which is the path
/// `PluginStore.delete` removes for a deleted plugin.
public final class PluginScratchStore:
    PluginFileWriting, PluginFileReading, PluginScratchGenerating, @unchecked Sendable {

    /// The generation a bridge writes into when nothing has opened one — a call
    /// that reached a bridge outside any hook. Its directory is reaped by
    /// `reapAll(pluginID:)` at the next load.
    public static let idleGeneration = "idle"

    private let rootURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    /// Plugin id → the open generation and how many holders it has.
    private var generations: [String: (id: String, holders: Int)] = [:]
    /// Descriptor id → the file it names.
    private var files: [String: URL] = [:]

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    // MARK: - Generations

    public func openScratchGeneration(pluginID: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let open = generations[pluginID] {
            generations[pluginID] = (open.id, open.holders + 1)
            return open.id
        }
        let id = UUID().uuidString
        generations[pluginID] = (id, 1)
        return id
    }

    public func closeScratchGeneration(pluginID: String) {
        lock.lock()
        guard let open = generations[pluginID] else {
            lock.unlock()
            return
        }
        guard open.holders <= 1 else {
            generations[pluginID] = (open.id, open.holders - 1)
            lock.unlock()
            return
        }
        generations[pluginID] = nil
        lock.unlock()
        reap(pluginID: pluginID, generation: open.id)
    }

    public func currentScratchGeneration(pluginID: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return generations[pluginID]?.id ?? Self.idleGeneration
    }

    public func hasOpenScratchGeneration(pluginID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[pluginID] != nil
    }

    // MARK: - Writing

    public func directoryURL(pluginID: String, generation: String) -> URL {
        rootURL
            .appendingPathComponent(pluginID, isDirectory: true)
            .appendingPathComponent(generation, isDirectory: true)
    }

    @discardableResult
    public func writeFile(
        _ data: Data, suggestedName: String, mime: String?, pluginID: String, generation: String
    ) throws -> PluginFileDescriptor {
        let directory = directoryURL(pluginID: pluginID, generation: generation)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = Self.safeName(suggestedName)
        let id = UUID().uuidString
        let url = directory.appendingPathComponent("\(id)-\(name)")
        try data.write(to: url, options: .atomic)
        lock.lock()
        files[id] = url
        lock.unlock()
        return PluginFileDescriptor(id: id, name: name, size: data.count, mime: mime)
    }

    /// Takes an EXISTING file into this generation's directory and describes
    /// it, without reading it into memory: a media save's download can be
    /// hundreds of megabytes, and the export hook gets a handle to it rather
    /// than its bytes. A hard link keeps one copy on disk; a volume that
    /// refuses one falls back to a copy, and the library's own file is never
    /// moved.
    @discardableResult
    public func adoptFile(
        at url: URL, suggestedName: String? = nil, mime: String? = nil,
        pluginID: String, generation: String
    ) throws -> PluginFileDescriptor {
        let directory = directoryURL(pluginID: pluginID, generation: generation)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = Self.safeName(suggestedName ?? url.lastPathComponent)
        let id = UUID().uuidString
        let destination = directory.appendingPathComponent("\(id)-\(name)")
        do {
            try fileManager.linkItem(at: url, to: destination)
        } catch {
            try fileManager.copyItem(at: url, to: destination)
        }
        let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        lock.lock()
        files[id] = destination
        lock.unlock()
        return PluginFileDescriptor(id: id, name: name, size: size, mime: mime)
    }

    /// The file a descriptor names, or nil when it was reaped or never written
    /// by this store.
    public func fileURL(for descriptor: PluginFileDescriptor) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = files[descriptor.id],
              fileManager.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    // MARK: - Reaping

    /// Removes one generation's directory and forgets the handles it held.
    public func reap(pluginID: String, generation: String) {
        try? fileManager.removeItem(
            at: directoryURL(pluginID: pluginID, generation: generation))
        lock.lock()
        files = files.filter { fileManager.fileExists(atPath: $0.value.path) }
        lock.unlock()
    }

    /// Drops every directory this plugin ever kept. Called when the plugin is
    /// deleted, and at load to clear what a killed process left.
    public func reapAll(pluginID: String) {
        try? fileManager.removeItem(
            at: rootURL.appendingPathComponent(pluginID, isDirectory: true))
        lock.lock()
        generations[pluginID] = nil
        files = files.filter { fileManager.fileExists(atPath: $0.value.path) }
        lock.unlock()
    }

    /// A file name that cannot escape its directory or hide as a dot file.
    static func safeName(_ raw: String) -> String {
        let trimmed = raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
        return name.isEmpty ? "file" : String(name.prefix(120))
    }
}
