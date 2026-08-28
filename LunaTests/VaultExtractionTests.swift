import Foundation
import LunaVaultEmbeddings
import LunaVaultIndexExtraction
import LunaVaultModels
import PDFKit
import UIKit
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
        let speech = TestSpeech(segments: [VaultSpokenWordSegment(text: "hello from video", startTime: 4.5, duration: 1.25)])
        let pipeline = VaultExtractionPipeline(ocr: ocr, transcriber: speech,
                                               imagePreparer: TestImagePreparer(),
                                               audioPreparer: TestAudioPreparer())
        let image = try await pipeline.extract(request(name: "scan.png", data: Data([0x89, 0x50, 0x4E, 0x47])))
        let video = try await pipeline.extract(request(name: "clip.mp4", data: Data([0, 1, 2])))
        XCTAssertEqual(image.chunks.first?.text, "serial 42")
        XCTAssertEqual(image.chunks.first?.provenance, .ocr)
        XCTAssertEqual(video.chunks.first?.text, "hello from video")
        XCTAssertEqual(video.chunks.first?.provenance, .speech)
        XCTAssertEqual(video.chunks.first?.location?.startTime, 4.5)
        XCTAssertEqual(video.chunks.first?.location?.endTime, 5.75)
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
        XCTAssertEqual(embedding.modelChecksum, model.checksum)
        XCTAssertNoThrow(try embedding.validated(for: model))
        do { _ = try await UnavailableVaultEmbeddingGenerator(model: model).embedding(for: "query"); XCTFail("missing model succeeded") }
        catch let error as VaultEmbeddingError { XCTAssertEqual(error, .modelUnavailable("fixture")) }
    }

    func testRTFUsesSystemParserAndPDFExtractsGeneratedText() async throws {
        let attributed = NSAttributedString(string: "Visible RTF text")
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rtfResult = try await VaultExtractionPipeline().extract(request(name: "note.rtf", data: rtf))
        XCTAssertTrue(rtfResult.chunks.first?.text.contains("Visible RTF text") == true)
        XCTAssertFalse(rtfResult.chunks.first?.text.contains("\\rtf") == true)

        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 300)).pdfData { context in
            context.beginPage(); ("Generated PDF text" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let pdfResult = try await VaultExtractionPipeline().extract(request(name: "note.pdf", data: pdfData))
        XCTAssertTrue(pdfResult.chunks.map(\.text).joined(separator: " ").contains("Generated PDF text"))
    }

    func testEncryptedPDFIsRejectedWithoutCredentialFlow() async throws {
        let sourceData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { context in
            context.beginPage(); ("secret" as NSString).draw(at: CGPoint(x: 10, y: 10), withAttributes: nil)
        }
        let source = try XCTUnwrap(PDFDocument(data: sourceData))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("locked.pdf")
        XCTAssertTrue(source.write(to: url, withOptions: [.userPasswordOption: "password",
                                                          .ownerPasswordOption: "owner-password"]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: url)).isEncrypted)
        do { _ = try await VaultExtractionPipeline().extract(request(name: "locked.pdf", data: try Data(contentsOf: url))); XCTFail("encrypted PDF was read") }
        catch let error as VaultExtractionError { XCTAssertEqual(error, .protectedDocument) }
    }

    func testHostileZIPBecomesMetadataOnlyBeforeDocumentParser() async throws {
        let zip = hostileZIP(uncompressedSize: 500_000_000, compressedSize: 1)
        let policy = VaultExtractionPolicy(maximumArchiveEntryBytes: 1_000_000,
                                           maximumArchiveTotalBytes: 2_000_000,
                                           maximumArchiveCompressionRatio: 10)
        XCTAssertThrowsError(try VaultZIPArchivePreflight().validate(zip, policy: policy))
        let result = try await VaultExtractionPipeline(policy: policy).extract(request(name: "hostile.docx", data: zip))
        XCTAssertTrue(result.metadata.isMetadataOnly)
        XCTAssertTrue(result.chunks.isEmpty)
    }

    func testImagePreparationRejectsPixelBombAndDownsamplesSafeImage() async throws {
        let imageData = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 50)).pngData { context in
            UIColor.red.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        }
        let preparer = SystemVaultImagePreparer()
        do { _ = try await preparer.prepareForOCR(imageData, policy: VaultExtractionPolicy(maximumImageDimension: 60)); XCTFail("oversized dimension accepted") }
        catch let error as VaultExtractionError { XCTAssertEqual(error, .unsafeImage("dimension")) }
        let prepared = try await preparer.prepareForOCR(imageData, policy: VaultExtractionPolicy(ocrMaximumPixelSize: 20))
        XCTAssertLessThanOrEqual(max(prepared.width, prepared.height), 20)
    }

    func testTimeoutCancelsSlowOCR() async throws {
        let slow = SlowOCR()
        let pipeline = VaultExtractionPipeline(policy: VaultExtractionPolicy(maximumWorkInterval: 0.02),
                                               ocr: slow, imagePreparer: TestImagePreparer())
        do { _ = try await pipeline.extract(request(name: "scan.png", data: Data([1]))); XCTFail("slow OCR completed") }
        catch let error as VaultExtractionError { XCTAssertEqual(error, .timedOut) }
        let wasCancelled = await slow.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testVideoDemuxSeamReceivesVideoAndSpeechPreservesSegments() async throws {
        let audio = TestAudioPreparer()
        let speech = TestSpeech(segments: [
            VaultSpokenWordSegment(text: "first", startTime: 1, duration: 0.5),
            VaultSpokenWordSegment(text: "second", startTime: 2, duration: 0.75)
        ])
        let result = try await VaultExtractionPipeline(transcriber: speech, audioPreparer: audio)
            .extract(request(name: "movie.mp4", data: Data([9, 8, 7])))
        XCTAssertEqual(audio.routes, [.video])
        XCTAssertEqual(speech.received, Data("demuxed".utf8))
        XCTAssertEqual(result.chunks.map(\.text), ["first", "second"])
        XCTAssertEqual(result.chunks.map { $0.location?.startTime }, [1, 2])
    }

    func testCoordinatorFailureIsSurfacedAndTransitionsAreDurable() async throws {
        let failing = TestCoordinator(beginError: VaultExtractionError.malformed("scheduler"))
        do { _ = try await VaultExtractionPipeline(jobCoordinator: failing).extract(request(name: "a.txt", data: Data("x".utf8))); XCTFail("scheduler failure hidden") }
        catch let error as VaultExtractionError { XCTAssertEqual(error, .malformed("scheduler")) }

        let coordinator = TestCoordinator()
        _ = try await VaultExtractionPipeline(workerID: "worker", jobCoordinator: coordinator)
            .extract(request(name: "a.txt", data: Data("x".utf8)))
        XCTAssertEqual(coordinator.transitions.map(\.0), [.succeeded])
    }

    func testCorruptCachedArtifactIsDiscardedAndRebuilt() async throws {
        let store = TestArtifactStore()
        let pipeline = VaultExtractionPipeline(artifactWriter: store)
        _ = try await pipeline.extract(request(name: "a.txt", data: Data("first".utf8)))
        store.corruptAll()
        let rebuilt = try await pipeline.extract(request(name: "a.txt", data: Data("second".utf8)))
        XCTAssertEqual(rebuilt.chunks.first?.text, "second")
        XCTAssertEqual(store.removeCount, 1)
        XCTAssertEqual(store.putCount, 2)
    }

    func testProductionSpeechExplicitlyRequiresOnDeviceRecognition() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("LunaLibraries/Sources/LunaVaultIndexExtraction/VaultSystemExtraction.swift"))
        XCTAssertTrue(source.contains("requiresOnDeviceRecognition = true"))
        XCTAssertFalse(source.contains("URLSession"))
    }

    private final class TestOCR: VaultVisionOCR, @unchecked Sendable {
        let observations: [VaultOCRObservation]; private(set) var callCount = 0
        init(observations: [VaultOCRObservation]) { self.observations = observations }
        func recognizeText(from data: Data, contentType: String?) async throws -> [VaultOCRObservation] { callCount += 1; return observations }
    }
    private final class TestSpeech: VaultSpeechSegmentTranscribing, @unchecked Sendable {
        let segments: [VaultSpokenWordSegment]; private(set) var callCount = 0; private(set) var received = Data()
        init(segments: [VaultSpokenWordSegment]) { self.segments = segments }
        func transcribeSegments(from data: Data, contentType: String?) async throws -> [VaultSpokenWordSegment] { callCount += 1; received = data; return segments }
    }
    private final class TestImagePreparer: VaultImagePreparing, @unchecked Sendable {
        func prepareForOCR(_ data: Data, policy: VaultExtractionPolicy) async throws -> VaultPreparedImage { VaultPreparedImage(data: data, width: 1, height: 1) }
    }
    private final class TestAudioPreparer: VaultAudioPreparing, @unchecked Sendable {
        private(set) var routes: [VaultFileRoute] = []
        func prepareAudio(from data: Data, route: VaultFileRoute, contentType: String?, policy: VaultExtractionPolicy) async throws -> VaultPreparedAudio { routes.append(route); return VaultPreparedAudio(data: Data("demuxed".utf8), duration: 3) }
    }
    private actor SlowOCR: VaultVisionOCR {
        private(set) var wasCancelled = false
        func recognizeText(from data: Data, contentType: String?) async throws -> [VaultOCRObservation] {
            do { try await Task.sleep(nanoseconds: 10_000_000_000); return [] }
            catch { wasCancelled = true; throw error }
        }
    }
    private final class TestCoordinator: VaultExtractionJobCoordinating, @unchecked Sendable {
        let beginError: Error?; private(set) var transitions: [(VaultJobState, String?)] = []
        init(beginError: Error? = nil) { self.beginError = beginError }
        func beginExtractionJob(objectID: VaultObjectID, revision: UUID, modelVersion: String, owner: String, now: Date, leaseDuration: TimeInterval) throws -> VaultExtractionJobLease { if let beginError { throw beginError }; return VaultExtractionJobLease(jobID: UUID(), owner: owner) }
        func transitionExtractionJob(_ lease: VaultExtractionJobLease, to state: VaultJobState, error: String?, retryAt: Date?, now: Date) throws { transitions.append((state, error)) }
    }
    private final class TestArtifactStore: VaultExtractionArtifactStoring, @unchecked Sendable {
        private var values: [String: Data] = [:]; private(set) var putCount = 0; private(set) var removeCount = 0
        func key(_ objectID: VaultObjectID, _ revision: UUID, _ version: String) -> String { "\(objectID.rawValue):\(revision):\(version)" }
        func extractionArtifact(objectID: VaultObjectID, revision: UUID, modelVersion: String) throws -> Data? { values[key(objectID, revision, modelVersion)] }
        func putExtractionArtifact(_ data: Data, objectID: VaultObjectID, revision: UUID, modelVersion: String) throws { values[key(objectID, revision, modelVersion)] = data; putCount += 1 }
        func removeExtractionArtifacts(for objectID: VaultObjectID) throws { values = values.filter { !$0.key.hasPrefix(objectID.rawValue.uuidString) }; removeCount += 1 }
        func corruptAll() { values = values.mapValues { Data($0.prefix(max(0, $0.count / 2))) } }
    }

    private func hostileZIP(uncompressedSize: UInt32, compressedSize: UInt32) -> Data {
        var data = Data(); func u16(_ value: UInt16) { data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8)) }; func u32(_ value: UInt32) { u16(UInt16(value & 0xffff)); u16(UInt16(value >> 16)) }
        let name = Data("bomb.xml".utf8); u32(0x02014B50); u16(20); u16(20); u16(0); u16(8); u16(0); u16(0); u32(0); u32(compressedSize); u32(uncompressedSize); u16(UInt16(name.count)); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0); data.append(name)
        let centralSize = UInt32(data.count); u32(0x06054B50); u16(0); u16(0); u16(1); u16(1); u32(centralSize); u32(0); u16(0); return data
    }
}
