import Foundation
import LunaVaultEmbeddings
import LunaVaultIndexExtraction
import LunaVaultModels
import XCTest

final class VaultExtractionTests: XCTestCase {
    private let objectID = VaultObjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)

    private func request(name: String, type: String? = nil, data: Data, bytes: Int64? = nil) -> VaultExtractionRequest {
        let revision = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let descriptor = VaultFileDescriptor(objectID: objectID, revision: revision, fileName: name,
                                             contentType: type, byteCount: bytes ?? Int64(data.count),
                                             createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
        return VaultExtractionRequest(descriptor: descriptor, data: data)
    }

    func testSnifferUsesMagicAndNeverTreatsArchiveAsText() {
        XCTAssertEqual(VaultFileTypeSniffer.route(fileName: "notes.txt", data: Data("hello".utf8)), .plainText)
        XCTAssertEqual(VaultFileTypeSniffer.route(fileName: "photo.bin", data: Data([0x89, 0x50, 0x4E, 0x47])), .image)
        XCTAssertEqual(VaultFileTypeSniffer.route(fileName: "archive.zip", data: Data("hello".utf8)), .metadataOnly)
        XCTAssertEqual(VaultFileTypeSniffer.route(fileName: "unknown", contentType: "text/plain", data: Data("hello".utf8)), .plainText)
    }

    func testTextIsBoundedAndChunkedWithoutSplittingUnicode() async throws {
        let text = String(repeating: "café 東京 ", count: 100)
        let policy = VaultExtractionPolicy(maximumTextBytes: 10_000, maximumChunks: 3, chunkCharacterCount: 20)
        let result = try await VaultExtractionPipeline(policy: policy).extract(request(name: "readme.md", data: Data(text.utf8)))
        XCTAssertEqual(result.route, .markdown)
        XCTAssertEqual(result.chunks.count, 3)
        XCTAssertEqual(result.chunks.map(\.index), [0, 1, 2])
        XCTAssertTrue(result.chunks.allSatisfy { !$0.text.isEmpty && $0.provenance == .markdown })
    }

    func testMetadataOnlyDoesNotInvokeOCROrSpeech() async throws {
        let result = try await VaultExtractionPipeline().extract(request(name: "encrypted.7z", data: Data([1, 2, 3])))
        XCTAssertTrue(result.metadata.isMetadataOnly)
        XCTAssertTrue(result.chunks.isEmpty)
    }

    func testImageOCRAndVideoSpeechAreInjectedAndOnDevice() async throws {
        let ocr = TestOCR(observations: [VaultOCRObservation(text: "serial 42", confidence: 0.9)])
        let speech = TestSpeech(text: "hello from video")
        let pipeline = VaultExtractionPipeline(ocr: ocr, transcriber: speech)
        let image = try await pipeline.extract(request(name: "scan.png", data: Data([0x89, 0x50, 0x4E, 0x47])))
        let video = try await pipeline.extract(request(name: "clip.mp4", data: Data([0, 1, 2])))
        XCTAssertEqual(image.chunks.first?.text, "serial 42")
        XCTAssertEqual(image.chunks.first?.provenance, .ocr)
        XCTAssertEqual(video.chunks.first?.text, "hello from video")
        XCTAssertEqual(video.chunks.first?.provenance, .speech)
        XCTAssertEqual(ocr.callCount, 1)
        XCTAssertEqual(speech.callCount, 1)
    }

    func testArtifactCacheIsRevisionAndModelVersionScoped() async throws {
        let store = TestArtifactStore()
        let pipeline = VaultExtractionPipeline(modelVersion: "extractor-v1", artifactWriter: store)
        let first = try await pipeline.extract(request(name: "a.txt", data: Data("cached".utf8)))
        let second = try await pipeline.extract(request(name: "a.txt", data: Data("different".utf8)))
        XCTAssertEqual(first, second)
        XCTAssertEqual(store.putCount, 1)
    }

    func testOversizeObjectFailsBeforeParsing() async {
        let request = request(name: "huge.txt", data: Data("small".utf8), bytes: 100_000_000_001)
        do {
            _ = try await VaultExtractionPipeline().extract(request)
            XCTFail("oversized input was accepted")
        } catch let error as VaultExtractionError {
            XCTAssertEqual(error, .inputTooLarge(100_000_000_001))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testEmbeddingChecksumDimensionAndNoModelFallback() async throws {
        let model = VaultEmbeddingModel(identifier: "fixture", version: "3", dimension: 8)
        let embedding = try await DeterministicVaultEmbeddingGenerator(model: model).embedding(for: "東京")
        XCTAssertEqual(embedding.dimension, 8)
        XCTAssertEqual(embedding.modelVersion, "3")
        XCTAssertNoThrow(try embedding.validated(for: model))
        do { _ = try await UnavailableVaultEmbeddingGenerator(model: model).embedding(for: "query"); XCTFail("missing model succeeded") }
        catch let error as VaultEmbeddingError { XCTAssertEqual(error, .modelUnavailable("fixture")) }
    }

    private final class TestOCR: VaultVisionOCR, @unchecked Sendable {
        let observations: [VaultOCRObservation]; private(set) var callCount = 0
        init(observations: [VaultOCRObservation]) { self.observations = observations }
        func recognizeText(from data: Data, contentType: String?) async throws -> [VaultOCRObservation] { callCount += 1; return observations }
    }
    private final class TestSpeech: VaultTranscribing, @unchecked Sendable {
        let text: String; private(set) var callCount = 0
        init(text: String) { self.text = text }
        func transcribeSpokenWords(from data: Data, contentType: String?) async throws -> VaultExtractedText { callCount += 1; return VaultExtractedText(text: text) }
    }
    private final class TestArtifactStore: VaultExtractionArtifactStoring, @unchecked Sendable {
        private var values: [String: Data] = [:]; private(set) var putCount = 0
        func key(_ objectID: VaultObjectID, _ revision: UUID, _ version: String) -> String { "\(objectID.rawValue):\(revision):\(version)" }
        func extractionArtifact(objectID: VaultObjectID, revision: UUID, modelVersion: String) throws -> Data? { values[key(objectID, revision, modelVersion)] }
        func putExtractionArtifact(_ data: Data, objectID: VaultObjectID, revision: UUID, modelVersion: String) throws { values[key(objectID, revision, modelVersion)] = data; putCount += 1 }
        func removeExtractionArtifacts(for objectID: VaultObjectID) throws { values = values.filter { !$0.key.hasPrefix(objectID.rawValue.uuidString) } }
    }
}
