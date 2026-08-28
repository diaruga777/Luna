import Foundation
import CryptoKit
#if canImport(PDFKit)
import PDFKit
#endif
import LunaDocuments
import LunaVaultModels

private struct VaultExtractionArtifactEnvelope: Codable {
    static let schemaVersion = 1
    let schema: Int
    let objectID: VaultObjectID
    let revision: UUID
    let modelVersion: String
    let resultChecksum: String
    let result: VaultExtractionResult
}

public struct VaultExtractionPipeline: Sendable {
    public let policy: VaultExtractionPolicy
    public let modelVersion: String
    public let workerID: String
    private let ocr: any VaultVisionOCR
    private let transcriber: any VaultSpeechSegmentTranscribing
    private let metadataProvider: any VaultMediaMetadataProviding
    private let imagePreparer: any VaultImagePreparing
    private let audioPreparer: any VaultAudioPreparing
    private let archivePreflight: any VaultArchivePreflighting
    private let artifactWriter: (any VaultExtractionArtifactStoring)?
    private let jobScheduler: (any VaultExtractionJobScheduling)?
    private let jobCoordinator: (any VaultExtractionJobCoordinating)?

    public init(policy: VaultExtractionPolicy = VaultExtractionPolicy(), modelVersion: String = "extractor-v2",
                workerID: String = "vault-extraction-\(UUID().uuidString)",
                ocr: any VaultVisionOCR = UnavailableVaultVisionOCR(),
                transcriber: any VaultSpeechSegmentTranscribing = UnavailableVaultSpeechTranscriber(),
                metadataProvider: any VaultMediaMetadataProviding = SystemVaultMediaMetadataProvider(),
                imagePreparer: any VaultImagePreparing = SystemVaultImagePreparer(),
                audioPreparer: any VaultAudioPreparing = SystemVaultAudioPreparer(),
                archivePreflight: any VaultArchivePreflighting = VaultZIPArchivePreflight(),
                artifactWriter: (any VaultExtractionArtifactStoring)? = nil,
                jobScheduler: (any VaultExtractionJobScheduling)? = nil,
                jobCoordinator: (any VaultExtractionJobCoordinating)? = nil) {
        self.policy = policy; self.modelVersion = modelVersion; self.workerID = workerID; self.ocr = ocr
        self.transcriber = transcriber; self.metadataProvider = metadataProvider; self.imagePreparer = imagePreparer
        self.audioPreparer = audioPreparer; self.archivePreflight = archivePreflight; self.artifactWriter = artifactWriter
        self.jobScheduler = jobScheduler; self.jobCoordinator = jobCoordinator
    }

    public func extract(_ request: VaultExtractionRequest) async throws -> VaultExtractionResult {
        let startedAt = Date()
        try checkBudget(startedAt)
        guard request.descriptor.byteCount <= policy.maximumObjectBytes else { throw VaultExtractionError.inputTooLarge(request.descriptor.byteCount) }
        guard Int64(request.data.count) <= policy.maximumObjectBytes else { throw VaultExtractionError.inputTooLarge(Int64(request.data.count)) }
        if let cached = try cachedResult(for: request) { return cached }

        let now = Date()
        let lease: VaultExtractionJobLease?
        if let jobCoordinator {
            lease = try jobCoordinator.beginExtractionJob(objectID: request.descriptor.objectID,
                                                           revision: request.descriptor.revision,
                                                           modelVersion: modelVersion, owner: workerID,
                                                           now: now, leaseDuration: policy.maximumWorkInterval + 30)
        } else {
            try jobScheduler?.enqueueExtractionJob(objectID: request.descriptor.objectID,
                                                   revision: request.descriptor.revision,
                                                   modelVersion: modelVersion)
            lease = nil
        }

        do {
            let result = try await performExtraction(request, startedAt: startedAt)
            try persist(result)
            if let lease { try jobCoordinator?.transitionExtractionJob(lease, to: .succeeded, error: nil, retryAt: nil, now: Date()) }
            return result
        } catch {
            if let lease {
                let transition: (VaultJobState, Date?)
                if error is CancellationError { transition = (.cancelled, nil) }
                else if error as? VaultExtractionError == .timedOut { transition = (.retrying, Date().addingTimeInterval(60)) }
                else { transition = (.failed, nil) }
                try jobCoordinator?.transitionExtractionJob(lease, to: transition.0,
                                                              error: String(describing: error),
                                                              retryAt: transition.1, now: Date())
            }
            throw error
        }
    }

    private func performExtraction(_ request: VaultExtractionRequest, startedAt: Date) async throws -> VaultExtractionResult {
        let route = VaultFileTypeSniffer.route(fileName: request.descriptor.fileName,
                                               contentType: request.descriptor.contentType,
                                               data: request.data)
        let metadata = try await withTimeout(remainingBudget(startedAt)) {
            try await metadataProvider.metadata(for: request.data,
                                                contentType: request.descriptor.contentType,
                                                fileName: request.descriptor.fileName)
        }
        try checkBudget(startedAt)
        var chunks: [VaultTextChunk] = []
        var duration = metadata.duration
        var metadataOnly = route == .metadataOnly || metadata.isMetadataOnly

        switch route {
        case .plainText, .markdown, .html, .richText, .pdf:
            chunks = try textChunks(route: route, request: request, startedAt: startedAt)
        case .wordDocument, .epub:
            do {
                try archivePreflight.validate(request.data, policy: policy)
                chunks = try textChunks(route: route, request: request, startedAt: startedAt)
            } catch VaultExtractionError.unsafeArchive {
                metadataOnly = true
            } catch VaultExtractionError.protectedDocument {
                metadataOnly = true
            }
        case .image:
            do {
                let prepared = try await withTimeout(remainingBudget(startedAt)) {
                    try await imagePreparer.prepareForOCR(request.data, policy: policy)
                }
                let observations = try await withTimeout(remainingBudget(startedAt)) {
                    try await ocr.recognizeText(from: prepared.data, contentType: "image/jpeg")
                }
                chunks = makeChunks(text: observations.map(\.text).joined(separator: "\n"), provenance: .ocr)
            } catch VaultExtractionError.unsafeImage {
                metadataOnly = true
            }
        case .audio, .video:
            do {
                let prepared = try await withTimeout(remainingBudget(startedAt)) {
                    try await audioPreparer.prepareAudio(from: request.data, route: route,
                                                         contentType: request.descriptor.contentType,
                                                         policy: policy)
                }
                duration = prepared.duration ?? duration
                let segments = try await withTimeout(remainingBudget(startedAt)) {
                    try await transcriber.transcribeSegments(from: prepared.data, contentType: "audio/mp4")
                }
                chunks = makeSpeechChunks(segments)
            } catch VaultExtractionError.noAudioTrack {
                metadataOnly = true
            } catch VaultExtractionError.mediaLimit {
                metadataOnly = true
            }
        case .metadataOnly:
            break
        }
        try checkBudget(startedAt)
        return VaultExtractionResult(descriptor: request.descriptor, route: route, chunks: chunks,
                                     metadata: VaultExtractedMetadata(title: metadata.title,
                                                                      mediaWidth: metadata.mediaWidth,
                                                                      mediaHeight: metadata.mediaHeight,
                                                                      duration: duration,
                                                                      isMetadataOnly: metadataOnly),
                                     modelVersion: modelVersion)
    }

    private func textChunks(route: VaultFileRoute, request: VaultExtractionRequest,
                            startedAt: Date) throws -> [VaultTextChunk] {
        if route == .pdf {
            #if canImport(PDFKit)
            let temporary = try VaultProtectedTemporaryDirectory(prefix: "pdf")
            defer { temporary.remove() }
            let url = try temporary.write(request.data, named: "document.pdf")
            guard let document = PDFDocument(url: url) else { throw VaultExtractionError.malformed("PDF") }
            // Even an owner-password-opened document is still encrypted. Vault
            // has no credential flow in v1, so all encrypted PDFs are rejected.
            guard !document.isEncrypted else { throw VaultExtractionError.protectedDocument }
            var text = ""
            for page in 0..<document.pageCount {
                try checkBudget(startedAt)
                let pageText = document.page(at: page)?.string ?? ""
                appendBounded(pageText + "\n\n", to: &text)
                if text.utf8.count >= policy.maximumTextBytes { break }
            }
            return makeChunks(text: text, provenance: .pdf)
            #else
            throw VaultExtractionError.unsupported("PDFKit")
            #endif
        }
        if route == .wordDocument || route == .epub {
            try checkBudget(startedAt)
            let temporary = try VaultProtectedTemporaryDirectory(prefix: "document")
            defer { temporary.remove() }
            let kind = route == .epub ? "epub" : "docx"
            let url = try temporary.write(request.data, named: "document.\(kind)")
            guard let content = DocumentParser.parse(fileURL: url, type: kind,
                                                     title: request.descriptor.fileName) else {
                throw VaultExtractionError.malformed(request.descriptor.fileName)
            }
            try checkBudget(startedAt)
            return makeChunks(text: content.blocks.map(\.text).joined(separator: "\n\n"),
                              provenance: route == .epub ? .epub : .wordDocument)
        }
        let bytes = request.data.prefix(policy.maximumTextBytes)
        if route == .richText {
            let attributed = try NSAttributedString(data: Data(bytes),
                                                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                    documentAttributes: nil)
            return makeChunks(text: attributed.string, provenance: .richText)
        }
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) else {
            throw VaultExtractionError.malformed("text")
        }
        let normalized = route == .html
            ? text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            : text
        return makeChunks(text: normalized, provenance: provenance(for: route))
    }

    private func cachedResult(for request: VaultExtractionRequest) throws -> VaultExtractionResult? {
        guard let artifactWriter,
              let payload = try artifactWriter.extractionArtifact(objectID: request.descriptor.objectID,
                                                                   revision: request.descriptor.revision,
                                                                   modelVersion: modelVersion) else { return nil }
        guard let envelope = try? JSONDecoder().decode(VaultExtractionArtifactEnvelope.self, from: payload),
              envelope.schema == VaultExtractionArtifactEnvelope.schemaVersion,
              envelope.objectID == request.descriptor.objectID,
              envelope.revision == request.descriptor.revision,
              envelope.modelVersion == modelVersion,
              envelope.result.descriptor.objectID == request.descriptor.objectID,
              envelope.result.descriptor.revision == request.descriptor.revision,
              envelope.result.modelVersion == modelVersion,
              envelope.resultChecksum == checksum(envelope.result) else {
            try artifactWriter.removeExtractionArtifacts(for: request.descriptor.objectID)
            return nil
        }
        return envelope.result
    }

    private func persist(_ result: VaultExtractionResult) throws {
        guard let artifactWriter else { return }
        let envelope = VaultExtractionArtifactEnvelope(schema: VaultExtractionArtifactEnvelope.schemaVersion,
                                                       objectID: result.descriptor.objectID,
                                                       revision: result.descriptor.revision,
                                                       modelVersion: result.modelVersion,
                                                       resultChecksum: checksum(result), result: result)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try artifactWriter.putExtractionArtifact(try encoder.encode(envelope), objectID: result.descriptor.objectID,
                                                 revision: result.descriptor.revision, modelVersion: result.modelVersion)
    }

    private func checksum(_ result: VaultExtractionResult) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(result)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func checkBudget(_ startedAt: Date) throws {
        try Task.checkCancellation()
        if Date().timeIntervalSince(startedAt) >= policy.maximumWorkInterval { throw VaultExtractionError.timedOut }
    }
    private func remainingBudget(_ startedAt: Date) -> TimeInterval {
        max(0.001, policy.maximumWorkInterval - Date().timeIntervalSince(startedAt))
    }
    private func appendBounded(_ value: String, to text: inout String) {
        let remaining = max(0, policy.maximumTextBytes - text.utf8.count)
        if remaining > 0 { text += String(decoding: value.utf8.prefix(remaining), as: UTF8.self) }
    }
    private func provenance(for route: VaultFileRoute) -> VaultTextProvenance {
        switch route { case .plainText: return .plainText; case .markdown: return .markdown; case .html: return .html
        case .richText: return .richText; case .pdf: return .pdf; case .wordDocument: return .wordDocument
        case .epub: return .epub; default: return .plainText }
    }
    private func makeChunks(text: String, provenance: VaultTextProvenance) -> [VaultTextChunk] {
        let boundedText = String(decoding: text.utf8.prefix(policy.maximumTextBytes), as: UTF8.self)
        var result: [VaultTextChunk] = []; var current = ""
        for word in boundedText.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > policy.chunkCharacterCount && !current.isEmpty {
                result.append(VaultTextChunk(index: result.count, text: current, provenance: provenance)); current = String(word)
                if result.count == policy.maximumChunks { return result }
            } else { current = candidate }
        }
        if !current.isEmpty && result.count < policy.maximumChunks { result.append(VaultTextChunk(index: result.count, text: current, provenance: provenance)) }
        return result
    }
    private func makeSpeechChunks(_ segments: [VaultSpokenWordSegment]) -> [VaultTextChunk] {
        var chunks: [VaultTextChunk] = []; var bytes = 0
        for segment in segments where chunks.count < policy.maximumChunks {
            let text = String(decoding: segment.text.utf8.prefix(max(0, policy.maximumTextBytes - bytes)), as: UTF8.self)
            guard !text.isEmpty else { break }; bytes += text.utf8.count
            chunks.append(VaultTextChunk(index: chunks.count, text: text, provenance: .speech,
                                         location: VaultTextLocation(startTime: segment.startTime,
                                                                     endTime: segment.startTime + segment.duration)))
        }
        return chunks
    }
}

private func withTimeout<T: Sendable>(_ interval: TimeInterval,
                                      operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0.001, interval) * 1_000_000_000))
            throw VaultExtractionError.timedOut
        }
        guard let value = try await group.next() else { throw VaultExtractionError.cancelled }
        group.cancelAll()
        return value
    }
}
