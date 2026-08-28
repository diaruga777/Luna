import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultEmbeddings
import LunaVaultIndexExtraction
import LunaVaultModels
import LunaVaultStorage
import VaultTestKit
import XCTest

final class VaultScaffoldTests: XCTestCase {
    private struct FixtureManifest: Decodable {
        struct FileEntry: Decodable {
            let id: UUID
            let contentType: String
            let text: String
        }

        let schemaVersion: Int
        let purpose: String
        let network: String
        let storageLocations: [String]
        let files: [FileEntry]
    }

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

    func testTemporaryDirectoriesAreUniqueAndPreserveExistingData() async throws {
        let base = try VaultTemporaryDirectory(name: "base")
        let sentinel = base.url.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)

        let directories = try await withThrowingTaskGroup(of: VaultTemporaryDirectory.self) { group in
            for _ in 0..<8 {
                group.addTask { try VaultTemporaryDirectory(name: "parallel", baseURL: base.url) }
            }
            var values: [VaultTemporaryDirectory] = []
            for try await directory in group { values.append(directory) }
            return values
        }
        XCTAssertEqual(Set(directories.map(\.url)).count, directories.count)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testFixtureManifestIsDecodableAndMatchesV1Contract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repositoryRoot.appendingPathComponent("Fixtures/Vault/manifest.json")
        let manifest = try JSONDecoder().decode(
            FixtureManifest.self,
            from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.network, "forbidden")
        XCTAssertEqual(manifest.storageLocations, ["device", "icloud", "mac"])
        XCTAssertEqual(Set(manifest.files.map(\.id)).count, manifest.files.count)
        XCTAssertTrue(manifest.files.allSatisfy { !$0.contentType.isEmpty && !$0.text.isEmpty })
        XCTAssertTrue(manifest.purpose.contains("deterministic"))
    }

    func testKeyStoreModelsKeychainIdentityLossAndRotation() throws {
        let synchronizable = VaultKeyDescriptor(
            service: "com.hsanabria.luna.vault.keys",
            account: "root",
            accessGroup: "team.com.hsanabria.luna.vault.keychain",
            synchronizable: true,
            accessibility: .afterFirstUnlock)
        let local = VaultKeyDescriptor(
            service: synchronizable.service,
            account: "device-cache",
            accessGroup: synchronizable.accessGroup,
            synchronizable: false,
            accessibility: .whenUnlocked)
        let store = InMemoryVaultKeyStore()
        try store.setData(Data([1]), for: synchronizable)
        try store.setData(Data([2]), for: local)
        XCTAssertEqual(store.rotateData(Data([3]), for: synchronizable), Data([1]))
        XCTAssertEqual(try store.data(for: synchronizable), Data([3]))
        XCTAssertEqual(Set(store.descriptors), [synchronizable, local])

        store.simulateDeviceLoss()
        XCTAssertEqual(try store.data(for: synchronizable), Data([3]))
        XCTAssertNil(try store.data(for: local))
        store.removeAll()
        XCTAssertTrue(store.descriptors.isEmpty)
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
        XCTAssertEqual(extractor.calls, [VaultExtractionCall(data: data, contentType: nil)])
        XCTAssertEqual(transcriber.calls, [VaultExtractionCall(data: data, contentType: "video/mp4")])
        XCTAssertEqual(embedder.calls, [VaultEmbeddingCall(text: "query")])

        let failure = VaultFakeTextExtractor(
            control: .failure(VaultFakeInjectedError("fixture failure")))
        do {
            _ = try await failure.extractText(from: data, contentType: "text/plain")
            XCTFail("Injected failure unexpectedly succeeded")
        } catch let error as VaultFakeInjectedError {
            XCTAssertEqual(error, VaultFakeInjectedError("fixture failure"))
        }
        XCTAssertEqual(failure.calls.count, 1)

        let cancellation = VaultFakeEmbedder(
            control: VaultFakeControl<VaultEmbedding>.cancellation)
        do {
            _ = try await cancellation.embedding(for: "cancel")
            XCTFail("Injected cancellation unexpectedly succeeded")
        } catch is CancellationError {
            XCTAssertEqual(cancellation.calls, [VaultEmbeddingCall(text: "cancel")])
        }
    }

    func testNoEgressProtocolAndRedactingLogger() async throws {
        let session = VaultNoEgressNetworkSessionProvider().session
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

        let secret = "root/key+?"
        let encoded = Data(secret.utf8).base64EncodedString()
        let percentEncoded = try XCTUnwrap(
            secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let logger = VaultRedactingLoggerSpy(secrets: [secret])
        logger.log(
            "{\"token\":\"\(encoded)\"}",
            metadata: ["authorization": "Bearer \(percentEncoded)", "raw": secret])
        let record = try XCTUnwrap(logger.records.first)
        XCTAssertEqual(record.message, "{\"token\":\"<redacted>\"}")
        XCTAssertEqual(record.metadata["authorization"], "Bearer <redacted>")
        XCTAssertEqual(record.metadata["raw"], "<redacted>")
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
