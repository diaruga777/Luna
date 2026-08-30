import Foundation
import UniformTypeIdentifiers
import LunaVaultModels

public enum LunaVaultIndexExtractionModule { public static let identifier = "LunaVaultIndexExtraction" }

public enum VaultExtractionError: Error, Equatable, Sendable {
    case inputTooLarge(Int64)
    case unsupported(String)
    case protectedDocument
    case modelUnavailable(String)
    case malformed(String)
    case unsafeArchive(String)
    case unsafeImage(String)
    case mediaLimit(String)
    case cancelled
    case timedOut
    case noAudioTrack
}

public enum VaultFileRoute: String, Codable, CaseIterable, Sendable {
    case plainText, markdown, html, richText, pdf, wordDocument, epub
    case image, audio, video, metadataOnly
}

public struct VaultExtractionPolicy: Codable, Equatable, Sendable {
    public let maximumObjectBytes: Int64
    public let maximumTextBytes: Int
    public let maximumChunks: Int
    public let chunkCharacterCount: Int
    public let maximumWorkInterval: TimeInterval
    public let maximumArchiveEntries: Int
    public let maximumArchiveEntryBytes: Int64
    public let maximumArchiveTotalBytes: Int64
    public let maximumArchiveCompressionRatio: Double
    public let maximumImageInputBytes: Int
    public let maximumImageDimension: Int
    public let maximumImagePixels: Int64
    public let maximumDecodedImageBytes: Int64
    public let ocrMaximumPixelSize: Int
    public let maximumMediaInputBytes: Int64
    public let maximumAudioOutputBytes: Int64
    public let maximumMediaDuration: TimeInterval
    /// Extraction is deliberately bounded separately from Vault's 100 GB
    /// import limit. Objects above this threshold are indexed as metadata-only
    /// and never materialised as one `Data` value.
    public let maximumMaterializedInputBytes: Int64

    public init(maximumObjectBytes: Int64 = 100_000_000_000, maximumTextBytes: Int = 16_000_000,
                maximumChunks: Int = 8_000, chunkCharacterCount: Int = 1_200,
                maximumWorkInterval: TimeInterval = 30, maximumArchiveEntries: Int = 2_048,
                maximumArchiveEntryBytes: Int64 = 32_000_000, maximumArchiveTotalBytes: Int64 = 128_000_000,
                maximumArchiveCompressionRatio: Double = 100, maximumImageInputBytes: Int = 64_000_000,
                maximumImageDimension: Int = 50_000, maximumImagePixels: Int64 = 200_000_000,
                maximumDecodedImageBytes: Int64 = 512_000_000, ocrMaximumPixelSize: Int = 4_096,
                maximumMediaInputBytes: Int64 = 4_000_000_000, maximumAudioOutputBytes: Int64 = 512_000_000,
                maximumMediaDuration: TimeInterval = 6 * 60 * 60,
                maximumMaterializedInputBytes: Int64 = 64 * 1024 * 1024) {
        self.maximumObjectBytes = max(1, maximumObjectBytes); self.maximumTextBytes = max(1, maximumTextBytes)
        self.maximumChunks = max(1, maximumChunks); self.chunkCharacterCount = max(1, chunkCharacterCount)
        self.maximumWorkInterval = max(0.1, maximumWorkInterval); self.maximumArchiveEntries = max(1, maximumArchiveEntries)
        self.maximumArchiveEntryBytes = max(1, maximumArchiveEntryBytes); self.maximumArchiveTotalBytes = max(1, maximumArchiveTotalBytes)
        self.maximumArchiveCompressionRatio = max(1, maximumArchiveCompressionRatio); self.maximumImageInputBytes = max(1, maximumImageInputBytes)
        self.maximumImageDimension = max(1, maximumImageDimension); self.maximumImagePixels = max(1, maximumImagePixels)
        self.maximumDecodedImageBytes = max(4, maximumDecodedImageBytes); self.ocrMaximumPixelSize = max(1, ocrMaximumPixelSize)
        self.maximumMediaInputBytes = max(1, maximumMediaInputBytes); self.maximumAudioOutputBytes = max(1, maximumAudioOutputBytes)
        self.maximumMediaDuration = max(1, maximumMediaDuration)
        self.maximumMaterializedInputBytes = max(1, maximumMaterializedInputBytes)
    }
}

public struct VaultFileDescriptor: Codable, Equatable, Sendable {
    public let objectID: VaultObjectID; public let revision: UUID; public let fileName: String
    public let contentType: String?; public let byteCount: Int64; public let createdAt: Date; public let updatedAt: Date
    public init(objectID: VaultObjectID, revision: UUID, fileName: String, contentType: String? = nil,
                byteCount: Int64, createdAt: Date, updatedAt: Date) {
        self.objectID = objectID; self.revision = revision; self.fileName = fileName; self.contentType = contentType
        self.byteCount = byteCount; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum VaultFileTypeSniffer {
    private static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "ipa", "app", "framework", "bundle", "car"]
    public static func route(fileName: String, contentType: String? = nil, data: Data? = nil) -> VaultFileRoute {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        if archiveExtensions.contains(ext) { return .metadataOnly }
        #if os(iOS) || os(macOS)
        if let mime = contentType, let type = UTType(mimeType: mime) {
            if type.conforms(to: .pdf) { return .pdf }; if type.conforms(to: .rtf) { return .richText }
            if type.conforms(to: .html) { return .html }; if type.conforms(to: .image) { return .image }
            if type.conforms(to: .audio) { return .audio }; if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .text) { return ext == "md" || ext == "markdown" ? .markdown : .plainText }
        }
        #endif
        switch ext {
        case "txt", "text", "log", "csv", "json", "xml", "yaml", "yml": return .plainText
        case "md", "markdown", "mdown": return .markdown
        case "html", "htm", "xhtml": return .html
        case "rtf": return .richText; case "pdf": return .pdf; case "docx": return .wordDocument; case "epub": return .epub
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp": return .image
        case "mp3", "m4a", "wav", "aac", "caf", "flac", "aiff": return .audio
        case "mp4", "mov", "m4v", "avi", "mkv", "webm": return .video
        default: break
        }
        if let data {
            if data.starts(with: Data("%PDF-".utf8)) { return .pdf }
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF]) { return .image }
            if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .metadataOnly }
        }
        return .metadataOnly
    }
}

public enum VaultTextProvenance: String, Codable, Sendable { case plainText, markdown, html, richText, pdf, wordDocument, epub, ocr, speech }
public struct VaultTextLocation: Codable, Equatable, Sendable {
    public let page: Int?; public let start: Int?; public let end: Int?; public let startTime: TimeInterval?; public let endTime: TimeInterval?
    public init(page: Int? = nil, start: Int? = nil, end: Int? = nil, startTime: TimeInterval? = nil, endTime: TimeInterval? = nil) { self.page = page; self.start = start; self.end = end; self.startTime = startTime; self.endTime = endTime }
}
public struct VaultTextChunk: Codable, Equatable, Sendable {
    public let index: Int; public let text: String; public let provenance: VaultTextProvenance; public let location: VaultTextLocation?
    public init(index: Int, text: String, provenance: VaultTextProvenance, location: VaultTextLocation? = nil) { self.index = index; self.text = text; self.provenance = provenance; self.location = location }
}
public struct VaultOCRObservation: Codable, Equatable, Sendable {
    public let text: String; public let confidence: Double; public let boundingBox: VaultNormalizedRect?
    public init(text: String, confidence: Double = 0, boundingBox: VaultNormalizedRect? = nil) { self.text = text; self.confidence = confidence; self.boundingBox = boundingBox }
}
public struct VaultNormalizedRect: Codable, Equatable, Sendable {
    public let x: Double; public let y: Double; public let width: Double; public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}
public struct VaultSpokenWordSegment: Codable, Equatable, Sendable {
    public let text: String; public let startTime: TimeInterval; public let duration: TimeInterval
    public init(text: String, startTime: TimeInterval, duration: TimeInterval) { self.text = text; self.startTime = startTime; self.duration = duration }
}
public struct VaultExtractedMetadata: Codable, Equatable, Sendable {
    public let title: String?; public let mediaWidth: Int?; public let mediaHeight: Int?; public let duration: TimeInterval?; public let isMetadataOnly: Bool
    public init(title: String? = nil, mediaWidth: Int? = nil, mediaHeight: Int? = nil, duration: TimeInterval? = nil, isMetadataOnly: Bool = false) { self.title = title; self.mediaWidth = mediaWidth; self.mediaHeight = mediaHeight; self.duration = duration; self.isMetadataOnly = isMetadataOnly }
}
public struct VaultExtractionResult: Codable, Equatable, Sendable {
    public let descriptor: VaultFileDescriptor; public let route: VaultFileRoute; public let chunks: [VaultTextChunk]
    public let metadata: VaultExtractedMetadata; public let modelVersion: String; public let extractedAt: Date
    public init(descriptor: VaultFileDescriptor, route: VaultFileRoute, chunks: [VaultTextChunk], metadata: VaultExtractedMetadata = VaultExtractedMetadata(), modelVersion: String = "extractor-v2", extractedAt: Date = Date()) { self.descriptor = descriptor; self.route = route; self.chunks = chunks; self.metadata = metadata; self.modelVersion = modelVersion; self.extractedAt = extractedAt }
}

public struct VaultExtractedText: Equatable, Sendable { public let text: String; public init(text: String) { self.text = text } }
public struct VaultPreparedImage: Equatable, Sendable { public let data: Data; public let width: Int; public let height: Int; public init(data: Data, width: Int, height: Int) { self.data = data; self.width = width; self.height = height } }
public struct VaultPreparedAudio: Equatable, Sendable { public let data: Data; public let duration: TimeInterval?; public init(data: Data, duration: TimeInterval? = nil) { self.data = data; self.duration = duration } }

public protocol VaultVisionOCR: Sendable { func recognizeText(from data: Data, contentType: String?) async throws -> [VaultOCRObservation] }
public protocol VaultTextExtracting: Sendable { func extractText(from data: Data, contentType: String?) async throws -> VaultExtractedText }
public protocol VaultTranscribing: Sendable { func transcribeSpokenWords(from data: Data, contentType: String?) async throws -> VaultExtractedText }
public protocol VaultSpeechSegmentTranscribing: Sendable { func transcribeSegments(from data: Data, contentType: String?) async throws -> [VaultSpokenWordSegment] }
public protocol VaultMediaMetadataProviding: Sendable { func metadata(for data: Data, contentType: String?, fileName: String) async throws -> VaultExtractedMetadata }
public protocol VaultThumbnailGenerating: Sendable { func thumbnail(for data: Data, contentType: String?, maximumPixelSize: Int) async throws -> Data? }
public protocol VaultImagePreparing: Sendable { func prepareForOCR(_ data: Data, policy: VaultExtractionPolicy) async throws -> VaultPreparedImage }
public protocol VaultAudioPreparing: Sendable { func prepareAudio(from data: Data, route: VaultFileRoute, contentType: String?, policy: VaultExtractionPolicy) async throws -> VaultPreparedAudio }
public protocol VaultArchivePreflighting: Sendable { func validate(_ data: Data, policy: VaultExtractionPolicy) throws }

public struct UnavailableVaultVisionOCR: VaultVisionOCR { public init() {}; public func recognizeText(from data: Data, contentType: String?) async throws -> [VaultOCRObservation] { throw VaultExtractionError.modelUnavailable("Vision") } }
public struct UnavailableVaultSpeechTranscriber: VaultTranscribing, VaultSpeechSegmentTranscribing {
    public init() {}
    public func transcribeSpokenWords(from data: Data, contentType: String?) async throws -> VaultExtractedText { throw VaultExtractionError.modelUnavailable("on-device Speech") }
    public func transcribeSegments(from data: Data, contentType: String?) async throws -> [VaultSpokenWordSegment] { throw VaultExtractionError.modelUnavailable("on-device Speech") }
}

public struct VaultExtractionRequest: Sendable {
    public let descriptor: VaultFileDescriptor; public let data: Data
    public init(descriptor: VaultFileDescriptor, data: Data) { self.descriptor = descriptor; self.data = data }
}
