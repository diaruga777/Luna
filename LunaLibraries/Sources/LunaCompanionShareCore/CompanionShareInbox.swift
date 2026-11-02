import Foundation
import LunaAppConfig

/// Immutable, atomically published captures. Only the containing app edits its
/// library; an extension never overwrites a suspended player's JSON snapshot.
public struct CompanionShareCapture: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case note, document, song, podcast }
    public let id: UUID
    public let createdAt: Date
    public let kind: Kind
    public let text: String
    public let title: String
    public let filenames: [String]
    public let destinations: [String]
    public let newPlaylist: String
    public let playNext: Bool
    /// Stable metadata only. Signed stream URLs/headers belong to URLSession.
    public struct YouTube: Codable, Sendable {
        public let videoID: String
        public let author: String
        public let duration: Double
        public let maximumBytes: Int64
        public init(videoID: String, author: String, duration: Double, maximumBytes: Int64) {
            self.videoID = videoID; self.author = author; self.duration = duration; self.maximumBytes = maximumBytes
        }
    }
    public let youtube: YouTube?
    public init(kind: Kind, text: String = "", title: String = "", filenames: [String] = [],
                destinations: [String] = [], newPlaylist: String = "", playNext: Bool = false, youtube: YouTube? = nil) {
        id = UUID(); createdAt = Date(); self.kind = kind; self.text = text; self.title = title
        self.filenames = filenames; self.destinations = destinations
        self.newPlaylist = newPlaylist; self.playNext = playNext; self.youtube = youtube
    }
}

public struct CompanionShareChoices: Codable, Sendable {
    public struct Choice: Codable, Sendable {
        public let id: String
        public let title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }
    public var playlists: [Choice] = []
    public var audioLists: [Choice] = []
    public var downloadBytesAvailable: Int64?
    public var cellularDownloads: Bool?
    public init() {}
}

public struct CompanionShareInbox: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static func production(_ app: String) throws -> Self {
        guard ["writer", "music"].contains(app), let group = AppConfig.sharedContainerURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        return Self(root: group.appendingPathComponent("CompanionShares/" + app, isDirectory: true))
    }
    public func directory(for capture: CompanionShareCapture) -> URL { root.appendingPathComponent(capture.id.uuidString) }
    public func save(_ capture: CompanionShareCapture, files: [URL] = []) throws {
        guard capture.filenames.count == files.count,
              capture.filenames.allSatisfy({ !$0.isEmpty && ($0 as NSString).lastPathComponent == $0 && $0 != "." && $0 != ".." }),
              Set(capture.filenames).count == files.count else { throw CocoaError(.fileWriteInvalidFileName) }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("." + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for (index, file) in files.enumerated() {
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            try fm.copyItem(at: file, to: staging.appendingPathComponent(capture.filenames[index]))
        }
        try JSONEncoder().encode(capture).write(to: staging.appendingPathComponent("capture.json"), options: .atomic)
        try fm.moveItem(at: staging, to: directory(for: capture))
    }
    public func pending() throws -> [CompanionShareCapture] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try JSONDecoder().decode(CompanionShareCapture.self, from: Data(contentsOf: $0.appendingPathComponent("capture.json"))) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
    public func remove(_ capture: CompanionShareCapture) throws { try FileManager.default.removeItem(at: directory(for: capture)) }
    public func choices() throws -> CompanionShareChoices {
        let file = root.appendingPathComponent("choices.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return CompanionShareChoices() }
        return try JSONDecoder().decode(CompanionShareChoices.self, from: Data(contentsOf: file))
    }
    public func publish(_ choices: CompanionShareChoices) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("choices.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(choices)
        if (try? Data(contentsOf: destination)) != data { try data.write(to: destination, options: .atomic) }
    }
}
