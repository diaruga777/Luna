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

/// Aggregate limits for bytes a plugin creates through `luna.files.write` or
/// `luna.fetch({ as: "file" })`. Host-owned files adopted for an export are
/// exempt: they already belong to a save and can legitimately be much larger
/// than a plugin-created intermediate file.
public struct PluginScratchQuotas: Equatable, Sendable {
    public var maxFiles: Int
    public var maxBytes: Int

    public init(maxFiles: Int = 256, maxBytes: Int = 32 * 1024 * 1024) {
        self.maxFiles = max(0, maxFiles)
        self.maxBytes = max(0, maxBytes)
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

    /// Generation-qualified variants used by a runtime that can have an old
    /// context draining while a replacement context is already active. The
    /// defaults preserve source compatibility for small test fakes.
    func openScratchGeneration(pluginID: String, generationID: String) -> String
    func closeScratchGeneration(pluginID: String, generationID: String)
    func currentScratchGeneration(pluginID: String, generationID: String) -> String
    func hasOpenScratchGeneration(pluginID: String, generationID: String) -> Bool
    func reapAll(pluginID: String, generationID: String)
}

public extension PluginScratchGenerating {
    func openScratchGeneration(pluginID: String, generationID: String) -> String {
        openScratchGeneration(pluginID: pluginID)
    }

    func closeScratchGeneration(pluginID: String, generationID: String) {
        closeScratchGeneration(pluginID: pluginID)
    }

    func currentScratchGeneration(pluginID: String, generationID: String) -> String {
        currentScratchGeneration(pluginID: pluginID)
    }

    func hasOpenScratchGeneration(pluginID: String, generationID: String) -> Bool {
        hasOpenScratchGeneration(pluginID: pluginID)
    }

    func reapAll(pluginID: String, generationID: String) {
        reapAll(pluginID: pluginID)
    }
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
    private let quotas: PluginScratchQuotas
    private let isAvailable: Bool
    private let lock = NSLock()
    /// (Plugin id, runtime generation) → the open scratch directory and how
    /// many calls/operations hold it. The runtime generation is deliberately
    /// part of this key: a callback from a retired context must never close
    /// or write into its replacement's directory.
    private var generations: [GenerationKey: (id: String, holders: Int)] = [:]
    /// Descriptor id → the file it names and any quota charge. Adopted
    /// host files remain addressable but carry no plugin-created charge.
    private var files: [String: ScratchFile] = [:]

    private struct ScratchFile {
        let url: URL
        let pluginID: String
        let chargedBytes: Int
    }

    private struct GenerationKey: Hashable {
        let pluginID: String
        let runtimeID: String
    }

    public init(
        rootURL: URL, fileManager: FileManager = .default,
        quotas: PluginScratchQuotas = PluginScratchQuotas(), isAvailable: Bool = true
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.quotas = quotas
        self.isAvailable = isAvailable
    }

    // MARK: - Generations

    public func openScratchGeneration(pluginID: String) -> String {
        openScratchGeneration(pluginID: pluginID, generationID: "legacy")
    }

    public func openScratchGeneration(pluginID: String, generationID: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let key = GenerationKey(pluginID: pluginID, runtimeID: generationID)
        if let open = generations[key] {
            generations[key] = (open.id, open.holders + 1)
            return open.id
        }
        // Runtime generations are also directory names. This makes a stale
        // callback unable to accidentally recreate a fresh directory under a
        // replacement context. Legacy callers retain opaque UUID directories.
        let id = generationID == "legacy" ? UUID().uuidString : generationID
        generations[key] = (id, 1)
        return id
    }

    public func closeScratchGeneration(pluginID: String) {
        closeScratchGeneration(pluginID: pluginID, generationID: "legacy")
    }

    public func closeScratchGeneration(pluginID: String, generationID: String) {
        let key = GenerationKey(pluginID: pluginID, runtimeID: generationID)
        lock.lock()
        guard let open = generations[key] else {
            lock.unlock()
            return
        }
        guard open.holders <= 1 else {
            generations[key] = (open.id, open.holders - 1)
            lock.unlock()
            return
        }
        generations[key] = nil
        lock.unlock()
        reap(pluginID: pluginID, generation: open.id)
    }

    public func currentScratchGeneration(pluginID: String) -> String {
        currentScratchGeneration(pluginID: pluginID, generationID: "legacy")
    }

    public func currentScratchGeneration(pluginID: String, generationID: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return generations[GenerationKey(pluginID: pluginID, runtimeID: generationID)]?.id
            ?? Self.idleGeneration
    }

    public func hasOpenScratchGeneration(pluginID: String) -> Bool {
        hasOpenScratchGeneration(pluginID: pluginID, generationID: "legacy")
    }

    public func hasOpenScratchGeneration(pluginID: String, generationID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[GenerationKey(pluginID: pluginID, runtimeID: generationID)] != nil
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
        lock.lock()
        defer { lock.unlock() }
        guard isAvailable else { throw PluginScratchError.storageUnavailable }
        guard generation == Self.idleGeneration || generations.contains(where: {
            $0.key.pluginID == pluginID && $0.value.id == generation
        }) else {
            throw PluginScratchError.generationClosed
        }
        let usage = files.values.reduce(into: (files: 0, bytes: 0)) { usage, entry in
            guard entry.pluginID == pluginID, entry.chargedBytes > 0,
                  fileManager.fileExists(atPath: entry.url.path)
            else { return }
            usage.files += 1
            usage.bytes += entry.chargedBytes
        }
        guard usage.files < quotas.maxFiles,
              data.count <= quotas.maxBytes - min(usage.bytes, quotas.maxBytes)
        else { throw PluginScratchError.quotaExceeded }
        let directory = directoryURL(pluginID: pluginID, generation: generation)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = Self.safeName(suggestedName)
        let id = UUID().uuidString
        let url = directory.appendingPathComponent("\(id)-\(name)")
        try data.write(to: url, options: .atomic)
        files[id] = ScratchFile(url: url, pluginID: pluginID, chargedBytes: data.count)
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
        lock.lock()
        defer { lock.unlock() }
        guard isAvailable else { throw PluginScratchError.storageUnavailable }
        guard generation == Self.idleGeneration || generations.contains(where: {
            $0.key.pluginID == pluginID && $0.value.id == generation
        }) else {
            throw PluginScratchError.generationClosed
        }
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
        files[id] = ScratchFile(url: destination, pluginID: pluginID, chargedBytes: 0)
        return PluginFileDescriptor(id: id, name: name, size: size, mime: mime)
    }

    /// The file a descriptor names, or nil when it was reaped or never written
    /// by this store.
    public func fileURL(for descriptor: PluginFileDescriptor) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let file = files[descriptor.id],
              fileManager.fileExists(atPath: file.url.path)
        else { return nil }
        return file.url
    }

    // MARK: - Reaping

    /// Removes one generation's directory and forgets the handles it held.
    public func reap(pluginID: String, generation: String) {
        try? fileManager.removeItem(
            at: directoryURL(pluginID: pluginID, generation: generation))
        lock.lock()
        files = files.filter { fileManager.fileExists(atPath: $0.value.url.path) }
        lock.unlock()
    }

    /// Drops every directory this plugin ever kept. Called when the plugin is
    /// deleted, and at load to clear what a killed process left.
    public func reapAll(pluginID: String) {
        lock.lock()
        let hasOpen = generations.keys.contains { $0.pluginID == pluginID }
        lock.unlock()
        guard !hasOpen else { return }
        try? fileManager.removeItem(
            at: rootURL.appendingPathComponent(pluginID, isDirectory: true))
        lock.lock()
        files = files.filter { fileManager.fileExists(atPath: $0.value.url.path) }
        lock.unlock()
    }

    public func reapAll(pluginID: String, generationID: String) {
        let key = GenerationKey(pluginID: pluginID, runtimeID: generationID)
        lock.lock()
        let open = generations[key]
        lock.unlock()
        // Never remove a directory still owned by a call or operation. This
        // is what makes an old context safe to drain during reload.
        guard open == nil else { return }
        try? fileManager.removeItem(
            at: rootURL.appendingPathComponent(pluginID, isDirectory: true)
                .appendingPathComponent(generationID, isDirectory: true))
        lock.lock()
        files = files.filter { fileManager.fileExists(atPath: $0.value.url.path) }
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

public enum PluginScratchError: Error, Equatable, LocalizedError {
    case storageUnavailable
    case generationClosed
    case quotaExceeded

    public var code: String {
        switch self {
        case .storageUnavailable: return "storage-unavailable"
        case .generationClosed: return "generation-closed"
        case .quotaExceeded: return "quota-exceeded"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "the plugin scratch store is unavailable"
        case .generationClosed: return "the plugin scratch generation is closed"
        case .quotaExceeded: return "the plugin scratch quota was exceeded"
        }
    }
}
