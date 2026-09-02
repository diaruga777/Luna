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

/// Whether one invocation's scratch directory outlives the hook that made it.
///
/// The export stage retains a directory whose handle it is about to hand to a
/// share sheet; every other invocation is reaped as soon as the hook settles.
public enum PluginScratchRetention: String, Equatable, Sendable {
    case reaped
    case retained
}

/// Writes bytes into a scratch directory. `luna.fetch` with `as: "file"` uses
/// it, so the fetch service can hand back a file without knowing where the
/// plugin tier keeps one.
public protocol PluginFileWriting: AnyObject {
    func writeFile(
        _ data: Data, suggestedName: String, mime: String?, invocationID: String
    ) throws -> PluginFileDescriptor
}

/// The per-invocation scratch directories under
/// `<AppGroup>/Plugins/scratch/<pluginId>/<invocationId>/`.
///
/// A directory is reaped when its hook settles. `retain` is the one way to keep
/// one: the export stage calls it for a file it is about to hand to the share
/// sheet, which outlives the invocation that made it.
public final class PluginScratchStore: PluginFileWriting, @unchecked Sendable {

    private let pluginID: String
    private let rootURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var retained: Set<String> = []
    /// Descriptor id → the file it names, per invocation.
    private var files: [String: URL] = [:]

    public init(pluginID: String, rootURL: URL, fileManager: FileManager = .default) {
        self.pluginID = pluginID
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func directoryURL(invocationID: String) -> URL {
        rootURL
            .appendingPathComponent(pluginID, isDirectory: true)
            .appendingPathComponent(invocationID, isDirectory: true)
    }

    @discardableResult
    public func writeFile(
        _ data: Data, suggestedName: String, mime: String?, invocationID: String
    ) throws -> PluginFileDescriptor {
        let directory = directoryURL(invocationID: invocationID)
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

    /// Keeps this invocation's directory past the hook. The export stage calls
    /// it for a handle it is about to hand on.
    public func retain(invocationID: String) {
        lock.lock()
        retained.insert(invocationID)
        lock.unlock()
    }

    public func retention(invocationID: String) -> PluginScratchRetention {
        lock.lock()
        defer { lock.unlock() }
        return retained.contains(invocationID) ? .retained : .reaped
    }

    /// Removes the invocation's directory unless it was retained.
    @discardableResult
    public func reap(invocationID: String) -> PluginScratchRetention {
        let retention = self.retention(invocationID: invocationID)
        guard retention == .reaped else { return retention }
        try? fileManager.removeItem(at: directoryURL(invocationID: invocationID))
        lock.lock()
        files = files.filter { fileManager.fileExists(atPath: $0.value.path) }
        lock.unlock()
        return .reaped
    }

    /// Drops every directory this plugin ever kept. Called when the plugin is
    /// deleted, and at launch to clear what a killed process left.
    public func reapAll() {
        lock.lock()
        retained.removeAll()
        files.removeAll()
        lock.unlock()
        try? fileManager.removeItem(
            at: rootURL.appendingPathComponent(pluginID, isDirectory: true))
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
