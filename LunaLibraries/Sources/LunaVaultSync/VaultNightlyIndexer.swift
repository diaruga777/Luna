import CryptoKit
import Foundation
import LunaVaultEmbeddings
import LunaVaultIndexExtraction
import LunaVaultModels
import LunaVaultSearch
import LunaVaultStore

public struct VaultNightlyIndexResult: Equatable, Sendable {
    public var processed: Int = 0
    public var indexed: Int = 0
    public var deferred: Int = 0
    public var thumbnails: Int = 0

    public init(processed: Int = 0, indexed: Int = 0, deferred: Int = 0, thumbnails: Int = 0) {
        self.processed = processed; self.indexed = indexed; self.deferred = deferred; self.thumbnails = thumbnails
    }
}

/// Foreground-safe nightly projection of the mirrored index. Content is read
/// only from the bounded cache; a missing cache entry is deferred, never
/// silently indexed as an empty document. OCR, speech and embeddings remain
/// on-device through the injected system adapters.
public final class VaultNightlyIndexer: @unchecked Sendable {
    private let store: any VaultSyncStoring
    private let search: VaultSearchIndex
    private let extraction: VaultExtractionPipeline
    private let embeddings: any VaultEmbeddingGenerating
    private let thumbnailer: any VaultThumbnailGenerating
    private let fileManager: FileManager

    public init(store: any VaultSyncStoring, search: VaultSearchIndex,
                extraction: VaultExtractionPipeline = VaultExtractionPipeline(
                    ocr: SystemVaultVisionOCR(), transcriber: SystemVaultSpeechTranscriber()),
                embeddings: any VaultEmbeddingGenerating = NLContextualEmbeddingGenerator(),
                thumbnailer: any VaultThumbnailGenerating = SystemVaultThumbnailGenerator(),
                fileManager: FileManager = .default) {
        self.store = store; self.search = search; self.extraction = extraction
        self.embeddings = embeddings; self.thumbnailer = thumbnailer; self.fileManager = fileManager
    }

    public func run(limit: Int = 64, now: Date = Date()) async -> VaultNightlyIndexResult {
        var result = VaultNightlyIndexResult()
        guard let records = try? store.filesNeedingIndex(limit: max(1, limit)) else { return result }
        for record in records {
            if Task.isCancelled { break }
            result.processed += 1
            guard let url = cachedURL(for: record) else {
                result.deferred += 1
                continue
            }
            let data: Data
            if record.size <= 64 * 1024 * 1024 {
                guard let loaded = try? Data(contentsOf: url) else { result.deferred += 1; continue }
                data = loaded
            } else {
                data = Data()
            }
            do {
                let descriptor = VaultFileDescriptor(objectID: Self.objectID(for: record.name),
                    revision: Self.revision(for: record.blocksHash), fileName: record.name,
                    byteCount: record.size, createdAt: record.modified, updatedAt: record.modified)
                let materialized = record.size <= 64 * 1024 * 1024 ? data : Data()
                let extracted = try await extraction.extract(VaultExtractionRequest(descriptor: descriptor, data: materialized))
                let chunks = Array(extracted.chunks.prefix(VaultChunkEmbeddingCodec.maximumChunksPerFile))
                let chunkVectors = await makeChunkVectors(chunks)
                let documentEmbedding = average(chunkVectors.map { $0.values })
                let body = chunks.filter { (chunk: VaultTextChunk) in chunk.provenance != VaultTextProvenance.ocr && chunk.provenance != VaultTextProvenance.speech }.map { $0.text }.joined(separator: "\n\n")
                let ocr = chunks.filter { (chunk: VaultTextChunk) in chunk.provenance == VaultTextProvenance.ocr }.map { $0.text }.joined(separator: "\n")
                let transcript = chunks.filter { (chunk: VaultTextChunk) in chunk.provenance == VaultTextProvenance.speech }.map { $0.text }.joined(separator: "\n")
                let embedding = documentEmbedding.map { VaultEmbedding(values: $0, modelVersion: embeddingsModel.version, modelChecksum: embeddingsModel.checksum) }
                let document = VaultIndexedDocument(id: descriptor.objectID, revision: descriptor.revision,
                    logicalTime: record.modifiedS, deviceID: String(record.modifiedBy), filename: record.name,
                    bodyText: body, ocrText: ocr, transcriptText: transcript, createdAt: record.modified,
                    updatedAt: record.modified, accessedAt: now, source: .mac, embedding: embedding)
                _ = try search.upsert(document)
                if !chunkVectors.isEmpty { try persistChunkVectors(chunkVectors, for: record) }
                try store.markIndexed(name: record.name, blocksHash: record.blocksHash)
                result.indexed += 1
                if !data.isEmpty, let thumbnail = try? await thumbnailer.thumbnail(for: data, contentType: nil, maximumPixelSize: 512),
                   !thumbnail.isEmpty {
                    try persistThumbnail(thumbnail, for: record)
                    try store.markThumbnail(name: record.name, blocksHash: record.blocksHash)
                    result.thumbnails += 1
                }
            } catch {
                result.deferred += 1
            }
        }
        return result
    }

    private var embeddingsModel: VaultEmbeddingModel {
        if let generator = embeddings as? NLContextualEmbeddingGenerator { return generator.model }
        if let generator = embeddings as? DeterministicVaultEmbeddingGenerator { return generator.model }
        return VaultEmbeddingModel(identifier: "injected", version: "injected", dimension: 1)
    }

    private func makeChunkVectors(_ chunks: [VaultTextChunk]) async -> [VaultChunkEmbedding] {
        var vectors: [VaultChunkEmbedding] = []
        for chunk in chunks {
            guard let vector = try? await embeddings.embedding(for: chunk.text) else { continue }
            vectors.append(VaultChunkEmbedding(chunk: chunk.index, values: vector.values))
        }
        return vectors
    }

    private func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        var sum = Array(repeating: Float.zero, count: first.count)
        for vector in vectors where vector.count == sum.count { for (index, value) in vector.enumerated() { sum[index] += value } }
        let divisor = Float(vectors.count)
        return sum.map { $0 / divisor }
    }

    private func cachedURL(for record: VaultFileRecord) -> URL? {
        let url = store.cacheFileURL(for: record.name)
        return fileManager.fileExists(atPath: url.path) && record.isCachedCurrent ? url : nil
    }

    private func persistChunkVectors(_ vectors: [VaultChunkEmbedding], for record: VaultFileRecord) throws {
        let directory = store.rootURL.appendingPathComponent("EmbeddingChunks", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try VaultChunkEmbeddingCodec.encode(vectors).write(to: directory.appendingPathComponent(Self.key(for: record) + ".f16"), options: .atomic)
    }

    private func persistThumbnail(_ data: Data, for record: VaultFileRecord) throws {
        let directory = store.thumbnailDirectory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(Self.key(for: record) + ".jpg"), options: .atomic)
    }

    private static func key(for record: VaultFileRecord) -> String { SHA256.hash(data: Data(record.name.utf8) + record.blocksHash).map { String(format: "%02x", $0) }.joined() }

    private static func objectID(for name: String) -> VaultObjectID {
        let bytes = Array(SHA256.hash(data: Data(name.utf8)))
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return VaultObjectID(rawValue: uuid)
    }

    private static func revision(for data: Data) -> UUID {
        let bytes = Array(SHA256.hash(data: data))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
