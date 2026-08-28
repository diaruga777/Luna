import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(Speech)
import Speech
#endif
import LunaVaultModels
import LunaDocuments

public enum LunaVaultIndexExtractionModule { public static let identifier = "LunaVaultIndexExtraction" }

public enum VaultExtractionError: Error, Equatable, Sendable {
    case inputTooLarge(Int64), unsupported(String), protectedDocument
    case modelUnavailable(String), malformed(String), cancelled, timedOut
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
    public init(maximumObjectBytes: Int64 = 100_000_000_000, maximumTextBytes: Int = 16_000_000,
                maximumChunks: Int = 8_000, chunkCharacterCount: Int = 1_200,
                maximumWorkInterval: TimeInterval = 30) {
        self.maximumObjectBytes = max(1, maximumObjectBytes); self.maximumTextBytes = max(1, maximumTextBytes)
        self.maximumChunks = max(1, maximumChunks); self.chunkCharacterCount = max(1, chunkCharacterCount)
        self.maximumWorkInterval = max(0.1, maximumWorkInterval)
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
        if let data { if data.starts(with: Data("%PDF-".utf8)) { return .pdf }; if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF]) { return .image }; if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .metadataOnly } }
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
    public let descriptor: VaultFileDescriptor; public let route: VaultFileRoute; public let chunks: [VaultTextChunk]; public let metadata: VaultExtractedMetadata; public let modelVersion: String; public let extractedAt: Date
    public init(descriptor: VaultFileDescriptor, route: VaultFileRoute, chunks: [VaultTextChunk], metadata: VaultExtractedMetadata = VaultExtractedMetadata(), modelVersion: String = "extractor-v1", extractedAt: Date = Date()) { self.descriptor = descriptor; self.route = route; self.chunks = chunks; self.metadata = metadata; self.modelVersion = modelVersion; self.extractedAt = extractedAt }
}

public protocol VaultVisionOCR: Sendable { func recognizeText(from data: Data, contentType: String?) async throws -> [VaultOCRObservation] }
public protocol VaultTextExtracting: Sendable { func extractText(from data: Data, contentType: String?) async throws -> VaultExtractedText }
public struct VaultExtractedText: Equatable, Sendable { public let text: String; public init(text: String) { self.text = text } }
public protocol VaultTranscribing: Sendable { func transcribeSpokenWords(from data: Data, contentType: String?) async throws -> VaultExtractedText }
public protocol VaultSpeechSegmentTranscribing: Sendable { func transcribeSegments(from data: Data, contentType: String?) async throws -> [VaultSpokenWordSegment] }
public protocol VaultMediaMetadataProviding: Sendable { func metadata(for data: Data, contentType: String?, fileName: String) async throws -> VaultExtractedMetadata }
public protocol VaultThumbnailGenerating: Sendable { func thumbnail(for data: Data, contentType: String?, maximumPixelSize: Int) async throws -> Data? }

public struct UnavailableVaultVisionOCR: VaultVisionOCR { public init() {}; public func recognizeText(from data: Data, contentType: String?) async throws -> [VaultOCRObservation] { throw VaultExtractionError.modelUnavailable("Vision") } }
public struct UnavailableVaultSpeechTranscriber: VaultTranscribing, VaultSpeechSegmentTranscribing {
    public init() {}
    public func transcribeSpokenWords(from data: Data, contentType: String?) async throws -> VaultExtractedText { throw VaultExtractionError.modelUnavailable("on-device Speech") }
    public func transcribeSegments(from data: Data, contentType: String?) async throws -> [VaultSpokenWordSegment] { throw VaultExtractionError.modelUnavailable("on-device Speech") }
}
public struct SystemVaultMediaMetadataProvider: VaultMediaMetadataProviding {
    public init() {}
    public func metadata(for data: Data, contentType: String?, fileName: String) async throws -> VaultExtractedMetadata {
        let route = VaultFileTypeSniffer.route(fileName: fileName, contentType: contentType, data: data)
        if route == .image, let source = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] { return VaultExtractedMetadata(mediaWidth: properties[kCGImagePropertyPixelWidth] as? Int, mediaHeight: properties[kCGImagePropertyPixelHeight] as? Int) }
        return VaultExtractedMetadata(isMetadataOnly: route == .metadataOnly)
    }
}
public struct SystemVaultThumbnailGenerator: VaultThumbnailGenerating {
    public init() {}
    public func thumbnail(for data: Data, contentType: String?, maximumPixelSize: Int) async throws -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize] as CFDictionary), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, nil) else { return nil }
        let destinationData = NSMutableData(); guard let destination = CGImageDestinationCreateWithData(destinationData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }; CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary); guard CGImageDestinationFinalize(destination) else { return nil }; return destinationData as Data
    }
}

#if canImport(Vision)
public struct SystemVaultVisionOCR: VaultVisionOCR {
    public init() {}
    public func recognizeText(from data: Data, contentType: String?) async throws -> [VaultOCRObservation] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw VaultExtractionError.malformed("image") }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { item in guard let candidate = item.topCandidates(1).first else { return nil }; return VaultOCRObservation(text: candidate.string, confidence: Double(candidate.confidence), boundingBox: VaultNormalizedRect(x: item.boundingBox.origin.x, y: item.boundingBox.origin.y, width: item.boundingBox.width, height: item.boundingBox.height)) })
            }; request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { continuation.resume(throwing: error) }
        }
    }
}
#else
public typealias SystemVaultVisionOCR = UnavailableVaultVisionOCR
#endif

#if canImport(Speech)
public struct SystemVaultSpeechTranscriber: VaultTranscribing, VaultSpeechSegmentTranscribing {
    public init() {}
    public func transcribeSpokenWords(from data: Data, contentType: String?) async throws -> VaultExtractedText { VaultExtractedText(text: try await transcribeSegments(from: data, contentType: contentType).map(\.text).joined(separator: " ")) }
    public func transcribeSegments(from data: Data, contentType: String?) async throws -> [VaultSpokenWordSegment] {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw VaultExtractionError.modelUnavailable("on-device Speech") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("luna-vault-speech-\(UUID().uuidString).audio"); try data.write(to: url, options: .atomic); defer { try? FileManager.default.removeItem(at: url) }
        let request = SFSpeechURLRecognitionRequest(url: url); request.requiresOnDeviceRecognition = true
        return try await withCheckedThrowingContinuation { continuation in recognizer.recognitionTask(with: request) { result, error in if let error { continuation.resume(throwing: error); return }; guard let result, result.isFinal else { return }; continuation.resume(returning: result.bestTranscription.segments.map { VaultSpokenWordSegment(text: $0.substring, startTime: $0.timestamp, duration: $0.duration) }) } }
    }
}
#else
public typealias SystemVaultSpeechTranscriber = UnavailableVaultSpeechTranscriber
#endif

public struct VaultExtractionRequest: Sendable { public let descriptor: VaultFileDescriptor; public let data: Data; public init(descriptor: VaultFileDescriptor, data: Data) { self.descriptor = descriptor; self.data = data } }

public struct VaultExtractionPipeline: Sendable {
    public let policy: VaultExtractionPolicy; public let modelVersion: String
    private let ocr: any VaultVisionOCR; private let transcriber: any VaultTranscribing; private let metadataProvider: any VaultMediaMetadataProviding
    private let artifactWriter: (any VaultExtractionArtifactStoring)?; private let jobScheduler: (any VaultExtractionJobScheduling)?
    public init(policy: VaultExtractionPolicy = VaultExtractionPolicy(), modelVersion: String = "extractor-v1", ocr: any VaultVisionOCR = UnavailableVaultVisionOCR(), transcriber: any VaultTranscribing = UnavailableVaultSpeechTranscriber(), metadataProvider: any VaultMediaMetadataProviding = SystemVaultMediaMetadataProvider(), artifactWriter: (any VaultExtractionArtifactStoring)? = nil, jobScheduler: (any VaultExtractionJobScheduling)? = nil) { self.policy = policy; self.modelVersion = modelVersion; self.ocr = ocr; self.transcriber = transcriber; self.metadataProvider = metadataProvider; self.artifactWriter = artifactWriter; self.jobScheduler = jobScheduler }
    public func extract(_ request: VaultExtractionRequest) async throws -> VaultExtractionResult {
        let startedAt = Date()
        func checkBudget() throws { try Task.checkCancellation(); if Date().timeIntervalSince(startedAt) > policy.maximumWorkInterval { throw VaultExtractionError.timedOut } }
        try checkBudget(); guard request.descriptor.byteCount <= policy.maximumObjectBytes else { throw VaultExtractionError.inputTooLarge(request.descriptor.byteCount) }; guard Int64(request.data.count) <= policy.maximumObjectBytes else { throw VaultExtractionError.inputTooLarge(Int64(request.data.count)) }
        if let writer = artifactWriter, let existing = try writer.extractionArtifact(objectID: request.descriptor.objectID, revision: request.descriptor.revision, modelVersion: modelVersion), let cached = try? JSONDecoder().decode(VaultExtractionResult.self, from: existing) { return cached }
        try? jobScheduler?.enqueueExtractionJob(objectID: request.descriptor.objectID, revision: request.descriptor.revision, modelVersion: modelVersion)
        let route = VaultFileTypeSniffer.route(fileName: request.descriptor.fileName, contentType: request.descriptor.contentType, data: request.data); let metadata = try await metadataProvider.metadata(for: request.data, contentType: request.descriptor.contentType, fileName: request.descriptor.fileName); try checkBudget()
        var chunks: [VaultTextChunk] = []
        switch route {
        case .plainText, .markdown, .html, .richText, .pdf, .wordDocument, .epub: chunks = makeChunks(text: try textForRoute(route, request: request), provenance: provenance(for: route), policy: policy)
        case .image: chunks = makeChunks(text: try await ocr.recognizeText(from: request.data, contentType: request.descriptor.contentType).map(\.text).joined(separator: "\n"), provenance: .ocr, policy: policy)
        case .audio, .video: chunks = makeChunks(text: try await transcriber.transcribeSpokenWords(from: request.data, contentType: request.descriptor.contentType).text, provenance: .speech, policy: policy)
        case .metadataOnly: break
        }
        try checkBudget(); let result = VaultExtractionResult(descriptor: request.descriptor, route: route, chunks: chunks, metadata: VaultExtractedMetadata(title: metadata.title, mediaWidth: metadata.mediaWidth, mediaHeight: metadata.mediaHeight, duration: metadata.duration, isMetadataOnly: route == .metadataOnly || metadata.isMetadataOnly), modelVersion: modelVersion)
        if let writer = artifactWriter, let payload = try? JSONEncoder().encode(result) { try writer.putExtractionArtifact(payload, objectID: request.descriptor.objectID, revision: request.descriptor.revision, modelVersion: modelVersion) }
        return result
    }
    private func textForRoute(_ route: VaultFileRoute, request: VaultExtractionRequest) throws -> String {
        if route == .pdf {
            #if canImport(PDFKit)
            let url = try temporaryFile(request.data, ext: "pdf"); defer { try? FileManager.default.removeItem(at: url) }; guard let document = PDFDocument(url: url) else { throw VaultExtractionError.malformed("PDF") }; guard !document.isEncrypted || !document.isLocked else { throw VaultExtractionError.protectedDocument }; return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }.joined(separator: "\n\n")
            #else
            throw VaultExtractionError.unsupported("PDFKit")
            #endif
        }
        if route == .wordDocument || route == .epub {
            #if canImport(LunaDocuments)
            let url = try temporaryFile(request.data, ext: route == .epub ? "epub" : "docx"); defer { try? FileManager.default.removeItem(at: url) }; guard let content = DocumentParser.parse(fileURL: url, type: route == .epub ? "epub" : "docx", title: request.descriptor.fileName) else { throw VaultExtractionError.malformed(request.descriptor.fileName) }; return content.blocks.map(\.text).joined(separator: "\n\n")
            #else
            throw VaultExtractionError.unsupported("document adapter")
            #endif
        }
        let bytes = request.data.prefix(policy.maximumTextBytes); guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) else { throw VaultExtractionError.malformed("text") }
        if route == .html { return text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression).replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&") }; return text
    }
    private func temporaryFile(_ data: Data, ext: String) throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("luna-vault-\(UUID().uuidString).\(ext)"); try data.write(to: url, options: .atomic); return url }
    private func provenance(for route: VaultFileRoute) -> VaultTextProvenance { switch route { case .plainText: return .plainText; case .markdown: return .markdown; case .html: return .html; case .richText: return .richText; case .pdf: return .pdf; case .wordDocument: return .wordDocument; case .epub: return .epub; default: return .plainText } }
    private func makeChunks(text: String, provenance: VaultTextProvenance, policy: VaultExtractionPolicy) -> [VaultTextChunk] { let boundedText = String(decoding: text.utf8.prefix(policy.maximumTextBytes), as: UTF8.self); var result: [VaultTextChunk] = []; var current = ""; for word in boundedText.split(whereSeparator: { $0.isWhitespace }) { let candidate = current.isEmpty ? String(word) : current + " " + word; if candidate.count > policy.chunkCharacterCount && !current.isEmpty { result.append(VaultTextChunk(index: result.count, text: current, provenance: provenance)); current = String(word); if result.count == policy.maximumChunks { return result } } else { current = candidate } }; if !current.isEmpty && result.count < policy.maximumChunks { result.append(VaultTextChunk(index: result.count, text: current, provenance: provenance)) }; return result }
}
