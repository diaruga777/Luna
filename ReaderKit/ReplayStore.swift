//
//  ReplayStore.swift
//  ReaderKit
//

import Foundation

/// Persists terminated `Replay`s as zipped pretty-JSON in the app sandbox
/// Documents folder (NOT the App Group — replays are diagnostics local to each
/// process's sandbox). Protocol-ized so the recorder is testable against an
/// in-memory/temp store.
protocol ReplayStoring: Sendable {
    /// Serializes `replay` to pretty JSON in a `.txt`, zips it, and writes it to the
    /// Replays directory (overwriting any prior export with the same id). Synchronous
    /// so an extension that may be killed right after still completes the write.
    func write(_ replay: Replay)

    /// The export zip URL for `id` (whether or not it exists yet).
    func zipURL(for id: UUID) -> URL

    /// All stored replays' listing metadata, newest first.
    func storedReplays() -> [StoredReplay]

    /// The newest terminated replay whose item URL matches `itemURLString`, decoded
    /// from its zip, or nil.
    func newestReplay(forItemURLString itemURLString: String) -> Replay?
}

/// File-backed `ReplayStoring`. Layout, all under `Documents/Replays/`:
///   `<uuid>.zip`  — the export (contains a single `<uuid>.txt` of pretty JSON).
///   `index.json`  — a lightweight `[StoredReplayRecord]` so listing/lookup never
///                    unzips every export.
struct ReplayDiskStore: ReplayStoring {
    private let directory: URL
    private let fileManager = FileManager.default
    private static let lock = NSLock()

    /// `directory` defaults to `Documents/Replays`. Tests pass a temp directory.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = documents.appendingPathComponent("Replays", isDirectory: true)
        }
    }

    /// The JSON entry inside the directory's `index.json` — the listing metadata
    /// (no events) for one stored replay.
    private struct IndexRecord: Codable {
        var id: UUID
        var itemURLString: String
        var state: Replay.ReplayState
        var createdAt: Date
    }

    func zipURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).zip")
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    func write(_ replay: Replay) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let json = try? encoder.encode(replay) else { return }

        var zip = ZipArchiveWriter()
        zip.addEntry(path: "\(replay.metadata.id.uuidString).txt", data: json)
        let zipData = zip.archiveData()
        try? zipData.write(to: zipURL(for: replay.metadata.id), options: .atomic)

        upsertIndex(IndexRecord(
            id: replay.metadata.id, itemURLString: replay.metadata.itemURLString,
            state: replay.metadata.state, createdAt: replay.metadata.createdAt))
    }

    func storedReplays() -> [StoredReplay] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return loadIndex()
            .sorted { $0.createdAt > $1.createdAt }
            .map {
                StoredReplay(
                    id: $0.id, itemURLString: $0.itemURLString, state: $0.state,
                    createdAt: $0.createdAt, zipURL: zipURL(for: $0.id))
            }
    }

    func newestReplay(forItemURLString itemURLString: String) -> Replay? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let record = loadIndex()
            .filter({ $0.itemURLString == itemURLString })
            .max(by: { $0.createdAt < $1.createdAt })
        else { return nil }
        return decodeReplay(id: record.id)
    }

    // MARK: - Index

    private func loadIndex() -> [IndexRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([IndexRecord].self, from: data)) ?? []
    }

    private func upsertIndex(_ record: IndexRecord) {
        var records = loadIndex()
        if let existing = records.firstIndex(where: { $0.id == record.id }) {
            records[existing] = record
        } else {
            records.append(record)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Decodes the replay stored in `<id>.zip` by reading the single stored (=
    /// uncompressed) entry's bytes directly out of the zip — our writer only ever
    /// stores one uncompressed JSON entry, so no inflate is needed.
    private func decodeReplay(id: UUID) -> Replay? {
        guard let zipData = try? Data(contentsOf: zipURL(for: id)),
              let json = Self.firstStoredEntryData(inZip: zipData)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Replay.self, from: json)
    }

    /// Extracts the first local file entry's (uncompressed/stored) payload from a
    /// ZIP produced by `ZipArchiveWriter`. Returns nil if the signature/structure
    /// doesn't match a single stored entry.
    static func firstStoredEntryData(inZip data: Data) -> Data? {
        let bytes = [UInt8](data)
        // Local file header signature 0x04034b50 (little-endian: 50 4b 03 04).
        guard bytes.count > 30,
              bytes[0] == 0x50, bytes[1] == 0x4b, bytes[2] == 0x03, bytes[3] == 0x04
        else { return nil }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) }
        func u32(_ offset: Int) -> Int {
            Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
                | (Int(bytes[offset + 2]) << 16) | (Int(bytes[offset + 3]) << 24)
        }
        let compressedSize = u32(18)
        let nameLength = u16(26)
        let extraLength = u16(28)
        let dataStart = 30 + nameLength + extraLength
        guard dataStart + compressedSize <= bytes.count else { return nil }
        return Data(bytes[dataStart..<(dataStart + compressedSize)])
    }
}
