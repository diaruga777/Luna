import Foundation
import LunaVaultBackend
import LunaVaultEmbeddings
import LunaVaultIndexExtraction
import LunaVaultModels
import LunaVaultStorage
import VaultTestKit
import XCTest

final class VaultScaffoldTests: XCTestCase {
    func testV1StorageLocationsAndPolicies() {
        XCTAssertEqual(VaultStorageLocation.allCases, [.device, .iCloud, .mac])
        XCTAssertTrue(VaultStoragePolicy(location: .device, keepLocalCopy: false).keepLocalCopy)
        XCTAssertFalse(VaultStoragePolicy(location: .iCloud, keepLocalCopy: false).keepLocalCopy)
        XCTAssertEqual(VaultStorageConfiguration().databaseName, "vault.sqlite")
    }

    func testDeterministicPrimitivesAndTempDirectory() throws {
        let now = Date(timeIntervalSince1970: 100)
        let clock = VaultTestClock(now: now)
        XCTAssertEqual(clock.now(), now)
        clock.advance(by: 10)
        XCTAssertEqual(clock.now(), Date(timeIntervalSince1970: 110))

        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let generator = VaultTestUUIDGenerator(values: [uuid])
        XCTAssertEqual(generator.next(), uuid)
        XCTAssertEqual(generator.next(), uuid)
        let random = try VaultTestRandomBytes(seed: 7).bytes(count: 8)
        XCTAssertEqual(random.count, 8)

        let directory = try VaultTemporaryDirectory(name: "scaffold")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.url.path))
        try directory.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.url.path))
    }

    func testInMemoryFakesRoundTripOpaqueData() async throws {
        let id = VaultObjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let store = InMemoryVaultObjectStore()
        try store.setData(Data([1, 2, 3]), for: id)
        XCTAssertEqual(try store.data(for: id), Data([1, 2, 3]))

        let backend = InMemoryVaultBackend()
        try await backend.putCiphertext(Data([9, 8]), for: id)
        let ciphertext = try await backend.ciphertext(for: id)
        XCTAssertEqual(ciphertext, Data([9, 8]))
        let objectIDs = await backend.allObjectIDs()
        XCTAssertEqual(objectIDs, [id])
        try await backend.removeCiphertext(for: id)
        let removed = try await backend.ciphertext(for: id)
        XCTAssertNil(removed)
    }

    func testIndexingFakesNeverNeedNetwork() async throws {
        let data = Data("ignored by deterministic fake".utf8)
        let extractor = VaultFakeTextExtractor(text: "on-device text")
        let transcriber = VaultFakeTranscriber(transcript: "on-device speech")
        let embedder = VaultFakeEmbedder(values: [1, 0, 1])
        let extracted = try await extractor.extractText(from: data, contentType: nil)
        let transcript = try await transcriber.transcribeSpokenWords(from: data, contentType: "video/mp4")
        let embedding = try await embedder.embedding(for: "query")
        XCTAssertEqual(extracted.text, "on-device text")
        XCTAssertEqual(transcript.text, "on-device speech")
        XCTAssertEqual(embedding.values, [1, 0, 1])
    }

    func testNoEgressProtocolAndRedactingLogger() async throws {
        let session = URLSession(configuration: VaultNoEgressURLProtocol.sessionConfiguration())
        let request = URLRequest(url: URL(string: "https://example.invalid/egress")!)
        do {
            _ = try await session.data(for: request)
            XCTFail("The no-egress URL protocol unexpectedly allowed a request")
        } catch {
            // URLSession bridges the URLProtocol's typed error through an
            // NSError wrapper, so assert the stable error code rather than a
            // concrete Swift error cast.
            XCTAssertEqual((error as NSError).code, 2)
        }

        let logger = VaultRedactingLoggerSpy(secrets: ["secret-token", "root-key"])
        logger.log("token=secret-token key=root-key")
        XCTAssertEqual(logger.records.first?.message, "token=<redacted> key=<redacted>")
    }

    func testMacUsesTailscaleAsTransportOnly() {
        let mac = VaultMacConnectionConfiguration(endpoint: "vault-mac.tailnet.example", port: 49200)
        let configuration = VaultBackendConfiguration(location: .mac, macConnection: mac)
        XCTAssertEqual(configuration.location, .mac)
        XCTAssertEqual(configuration.macConnection?.endpoint, "vault-mac.tailnet.example")
        XCTAssertTrue(configuration.macConnection?.usesTailscale == true)
        XCTAssertNil(VaultBackendConfiguration(location: .device, macConnection: mac).macConnection)
    }
}
