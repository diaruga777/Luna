import Foundation

/// A process-safe handoff between the share extension and the Vault app. An
/// item is visible only after both its payload and manifest have been copied
/// into a private draft directory and the directory has been renamed.
struct VaultIncomingQueue {
    struct Item: Codable, Sendable {
        let id: String
        let relativeName: String
        let isDirectory: Bool
        let createdAt: Date
        let byteCount: Int64
        var destinationName: String? = nil
    }

    let rootURL: URL

    static func production(bundle: Bundle = .main) throws -> Self {
        guard let group = bundle.object(forInfoDictionaryKey: "LunaAppGroupID") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Self(rootURL: container.appendingPathComponent("Vault/Incoming", isDirectory: true))
    }

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: rootURL.path)
        #endif
        let staleBefore = Date().addingTimeInterval(-86_400)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in leftovers where url.lastPathComponent.hasPrefix(".") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if modified < staleBefore {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    @discardableResult
    func enqueueFile(at source: URL, relativeName: String, isDirectory: Bool = false) throws -> Item {
        try Task.checkCancellation()
        try Self.validate(relativeName)
        let type = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard type.isSymbolicLink != true,
              isDirectory ? type.isDirectory == true : type.isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let id = String(format: "%.6f", Date().timeIntervalSince1970) + "-" + UUID().uuidString
        let draft = rootURL.appendingPathComponent(".draft-" + id, isDirectory: true)
        let ready = rootURL.appendingPathComponent(id, isDirectory: true)
        let payload = draft.appendingPathComponent("payload", isDirectory: isDirectory)
        try FileManager.default.createDirectory(at: draft, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: draft) }
        if isDirectory {
            try FileManager.default.copyItem(at: source, to: payload)
        } else {
            // Bound memory and observe cancellation between chunks, including
            // a single large movie. Never publish a partially copied payload.
            var attributes: [FileAttributeKey: Any] = [:]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            guard FileManager.default.createFile(atPath: payload.path, contents: nil, attributes: attributes) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: payload)
            defer { try? output.close() }
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 1_024 * 1_024) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        }
        let size = (try? payload.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let item = Item(id: id, relativeName: relativeName, isDirectory: isDirectory,
                        createdAt: Date(), byteCount: size)
        try JSONEncoder().encode(item).write(to: draft.appendingPathComponent("item.json"), options: .atomic)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: payload.path)
        #endif
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: draft, to: ready)
        return item
    }

    @discardableResult
    func enqueueDirectory(relativeName: String) throws -> Item {
        let empty = rootURL.appendingPathComponent(".empty-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        return try enqueueFile(at: empty, relativeName: relativeName, isDirectory: true)
    }

    func items() throws -> [Item] {
        let urls = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])
        return urls.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? JSONDecoder().decode(Item.self, from: Data(contentsOf: $0.appendingPathComponent("item.json"))) }
    }

    func payloadURL(for item: Item) -> URL {
        rootURL.appendingPathComponent(item.id, isDirectory: true).appendingPathComponent("payload", isDirectory: item.isDirectory)
    }

    func remove(_ item: Item) throws {
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent(item.id, isDirectory: true))
    }

    func prepare(_ item: Item, destinationName: String) throws -> Item {
        try Self.validate(destinationName)
        var prepared = item
        prepared.destinationName = destinationName
        try JSONEncoder().encode(prepared).write(
            to: rootURL.appendingPathComponent(item.id, isDirectory: true).appendingPathComponent("item.json"),
            options: .atomic)
        return prepared
    }

    private static func validate(_ name: String) throws {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, !name.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }
}
