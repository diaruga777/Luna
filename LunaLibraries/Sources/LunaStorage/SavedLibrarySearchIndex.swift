import Accelerate
import Foundation
import LunaModels
import NaturalLanguage

/// No content decoding or document embedding on the query path. FTS is written
/// with the article; normalized chunk vectors live in SQLite and are warmed into
/// memory at launch. A separate query queue stays responsive during backfill.
public final class SavedLibrarySearchIndex: SavesSweepForegroundTracking {
    public static let shared = SavedLibrarySearchIndex(store: .shared)
    public static let didUpdate = Notification.Name("savedLibraryIndexDidUpdate")
    private let store: SavesStore
    private let modelQueue = DispatchQueue(label: "luna.library.embedding")
    private let snapshotLock = NSLock()
    private var embedding: NLEmbedding?
    private var modelReady = false
    private var vectors: [IndexedVector] = []
    private var warmedKey: String?
    private let testEmbedding: ((String) -> [Double]?)?

    private lazy var driver = SavesSweepDriver(
        queueLabel: "luna.library.index", debounceInterval: 0.3, sweeper: self)

    private struct IndexedVector {
        let id: UUID
        let generation: Int64
        let values: [Float]
    }

    public init(store: SavesStore) { self.store = store; self.testEmbedding = nil }
    init(store: SavesStore, embedding: @escaping (String) -> [Double]?) {
        self.store = store
        self.testEmbedding = embedding
    }

    public func install() { driver.install() }
    public func savesSweepForegroundChanged(to isForeground: Bool) {}

    public func runSavesSweep() {
        let model = modelQueue.sync { () -> String in
            if !modelReady {
                if testEmbedding == nil { embedding = NLEmbedding.sentenceEmbedding(for: .english) }
                modelReady = true
            }
            if testEmbedding != nil { return "test-v1" }
            return embedding.map { "nl-en-\($0.revision)" } ?? "nl-en-unavailable"
        }
        do {
            try warmVectors(model: model)
            let items = Dictionary(uniqueKeysWithValues: store.items().map { ($0.id, $0) })
            var backfill: [(UUID, Int64)] = []
            try store.libraryIndexRead { db in
                try db.query("SELECT save_id, generation FROM library_documents WHERE needs_backfill=1") {
                    if let id = $0.string(0).flatMap(UUID.init(uuidString:)) {
                        backfill.append((id, $0.int64(1)))
                    }
                }
            }
            for (id, generation) in backfill {
                guard let item = items[id] else { continue }
                let body = store.content(for: item).map(SavedLibrarySearchSchema.text) ?? ""
                try store.libraryIndexWrite { db in
                    // A simultaneous saveContent wins over this historical read.
                    guard try db.scalarInt("""
                        SELECT 1 FROM library_documents
                        WHERE save_id=? AND generation=? AND needs_backfill=1
                        """, { try $0.bind(1, uuid: id); try $0.bind(2, generation) }) != nil
                    else { return }
                    try SavedLibrarySearchSchema.setBody(body, id: id, in: db)
                }
            }
            var pending: [(UUID, String, Int64)] = []
            try store.libraryIndexRead { db in
                try db.query("""
                    SELECT save_id, title || char(10) || body, generation FROM library_documents
                    WHERE needs_backfill=0 AND (embedded_generation != generation OR model IS NOT ?)
                    """, { try $0.bind(1, model) }) {
                    if let id = $0.string(0).flatMap(UUID.init(uuidString:)) {
                        pending.append((id, $0.string(1) ?? "", $0.int64(2)))
                    }
                }
            }
            for (id, text, generation) in pending {
                let chunks = Self.chunks(text).compactMap { vector(for: $0) }
                try store.libraryIndexWrite { db in
                    guard try db.scalarInt(
                        "SELECT 1 FROM library_documents WHERE save_id=? AND generation=?",
                        { try $0.bind(1, uuid: id); try $0.bind(2, generation) }) != nil
                    else { return }
                    try db.run("DELETE FROM library_vectors WHERE save_id=?") { try $0.bind(1, uuid: id) }
                    for (ordinal, values) in chunks.enumerated() {
                        try db.run("INSERT INTO library_vectors VALUES(?, ?, ?, ?)") {
                            try $0.bind(1, uuid: id)
                            try $0.bind(2, ordinal)
                            try $0.bind(3, values.count)
                            try $0.bind(4, blob: values.withUnsafeBufferPointer { Data(buffer: $0) })
                        }
                    }
                    try db.run("UPDATE library_documents SET embedded_generation=?, model=? WHERE save_id=?") {
                        try $0.bind(1, generation)
                        try $0.bind(2, model)
                        try $0.bind(3, uuid: id)
                    }
                }
            }
            try warmVectors(model: model)
            if !backfill.isEmpty || !pending.isEmpty {
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didUpdate, object: nil) }
            }
        } catch {
            SharedDiagnosticLog.record("Library indexing: \(error)", category: "search")
        }
    }

    /// Called off-main. Exact/prefix matches lead; semantic retrieval searches
    /// ALL current chunks, including saves with no matching query words.
    public func matches(_ query: String) throws -> [UUID] {
        let tokens = Self.tokens(query)
        guard !tokens.isEmpty else { return [] }
        let expression = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
        let queryVector = query.count >= 3 ? vector(for: query) : nil
        var lexical: [UUID] = []
        var generations: [UUID: Int64] = [:]
        try store.libraryIndexRead { db in
            try db.readTransaction {
                try db.query("""
                    SELECT d.save_id FROM library_fts
                    JOIN library_documents d ON d.rowid=library_fts.rowid
                    WHERE library_fts MATCH ? ORDER BY bm25(library_fts, 6, 1)
                    """, { try $0.bind(1, expression) }) {
                    if let id = $0.string(0).flatMap(UUID.init(uuidString:)) { lexical.append(id) }
                }
                if queryVector != nil {
                    try db.query("SELECT save_id, generation FROM library_documents") {
                        if let id = $0.string(0).flatMap(UUID.init(uuidString:)) {
                            generations[id] = $0.int64(1)
                        }
                    }
                }
            }
        }
        guard let queryVector else { return lexical }
        snapshotLock.lock()
        let snapshot = vectors
        snapshotLock.unlock()
        var semantic: [UUID: Float] = [:]
        for candidate in snapshot where candidate.generation == generations[candidate.id]
            && candidate.values.count == queryVector.count {
            var similarity: Float = 0
            vDSP_dotpr(candidate.values, 1, queryVector, 1, &similarity, vDSP_Length(queryVector.count))
            if similarity >= 0.4 { semantic[candidate.id] = max(semantic[candidate.id] ?? 0, similarity) }
        }
        // Keep exact lexical hits at the front, then meaning-only hits. Chunk
        // count never boosts a long article over a short one.
        let exact = Set(lexical)
        return lexical + semantic.filter { !exact.contains($0.key) }
            .sorted { $0.value == $1.value ? $0.key.uuidString < $1.key.uuidString : $0.value > $1.value }
            .map(\.key)
    }

    private func vector(for text: String) -> [Float]? {
        modelQueue.sync {
            guard modelReady, let values = testEmbedding?(text) ?? embedding?.vector(for: text),
                  values.allSatisfy(\.isFinite) else { return nil }
            let magnitude = sqrt(values.reduce(0) { $0 + $1 * $1 })
            guard magnitude > 0 else { return nil }
            return values.map { Float($0 / magnitude) }
        }
    }

    private func warmVectors(model: String) throws {
        var loaded: [IndexedVector] = []
        var key = ""
        try store.libraryIndexRead { db in
            try db.query("SELECT revision FROM library_index_state WHERE singleton=1") {
                key = "\(model)-\($0.int64(0))"
            }
            guard key != warmedKey else { return }

            try db.query("""
                SELECT v.save_id, d.generation, v.dimensions, v.vector FROM library_vectors v
                JOIN library_documents d ON d.save_id=v.save_id
                WHERE d.generation=d.embedded_generation AND d.model=?
                """, { try $0.bind(1, model) }) {
                guard let id = $0.string(0).flatMap(UUID.init(uuidString:)),
                      let count = $0.int(2), count > 0, let data = $0.blob(3),
                      data.count == count * MemoryLayout<Float>.size else { return }
                let values = data.withUnsafeBytes { raw in
                    (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
                }
                guard values.allSatisfy(\.isFinite) else { return }
                loaded.append(IndexedVector(id: id, generation: $0.int64(1), values: values))
            }
        }
        guard key != warmedKey else { return }
        warmedKey = key
        snapshotLock.lock()
        vectors = loaded
        snapshotLock.unlock()
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Pack complete sentences within paragraphs, capped at 120 words. Carry
    /// the preceding sentence across each boundary for context; unusually long
    /// sentences split into bounded word runs without losing any text.
    static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var current: [String] = []
        var words = 0
        for paragraph in text.components(separatedBy: .newlines) where !paragraph.isEmpty {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = paragraph
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                let sentence = String(paragraph[range])
                let parts = sentence.split(whereSeparator: \.isWhitespace)
                for start in stride(from: 0, to: parts.count, by: 120) {
                    let slice = parts[start..<min(start + 120, parts.count)]
                    if words + slice.count > 120, !current.isEmpty {
                        result.append(current.joined(separator: " "))
                        let tail = current.last ?? ""
                        let tailCount = tail.split(whereSeparator: \.isWhitespace).count
                        current = tailCount + slice.count <= 120 ? [tail] : []
                        words = current.isEmpty ? 0 : tailCount
                    }
                    current.append(slice.joined(separator: " "))
                    words += slice.count
                }
                return true
            }
            // Respect section/paragraph boundaries when the current chunk has
            // enough substance, keeping short headings with their next prose.
            if words >= 60 { result.append(current.joined(separator: " ")); current = []; words = 0 }
        }
        if !current.isEmpty { result.append(current.joined(separator: " ")) }
        return result
    }
}
