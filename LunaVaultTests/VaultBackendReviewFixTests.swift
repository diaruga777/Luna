import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import VaultTestKit
import XCTest

/// Regression coverage for the LunaVaultBackend review pass (client
/// transports cluster) that is cheap to pin against the in-process fakes:
/// findings that need the Mac companion/handshake harness live alongside it
/// in `VaultMacProtocolAndStoreTests`.
final class VaultBackendReviewFixTests: XCTestCase {
    func testICloudPayloadAndPayloadFileReturnNilRatherThanStaleVersionForAnObjectThatNeverExisted() async throws {
        let coordinator = InMemoryVaultUbiquitousCoordinator()
        let backend = VaultICloudBackend(configuration: VaultICloudBackendConfiguration(
            containerIdentifier: "iCloud.review-fix"), coordinator: coordinator)
        let neverWritten = try VaultRemoteObjectIdentity(
            objectID: VaultObjectID(rawValue: UUID()), revision: UUID(),
            kind: .content, generation: String(repeating: "a", count: 64))
        // No `current.json` was ever written for this object: absent
        // history is `.notFound` (nil), not a version mismatch.
        let payload = try await backend.payload(for: neverWritten)
        XCTAssertNil(payload)
        let payloadFile = try await backend.payloadFile(for: neverWritten)
        XCTAssertNil(payloadFile)
    }

    func testValidHostnameRejectsNonASCIIConfusableLabels() {
        // A Cyrillic "а" (U+0430) satisfies Unicode `isLetter` but is not
        // the ASCII "a" a real Tailscale/Bonjour label is built from.
        let confusable = "v\u{0430}ult.example.ts.net"
        XCTAssertThrowsError(try VaultMacEndpoint(host: confusable, port: 49_200, reachability: .tailscale))
        XCTAssertNoThrow(try VaultMacEndpoint(host: "vault.example.ts.net", port: 49_200, reachability: .tailscale))
    }

    func testVaultMacPendingUploadDecodesRecordsWithoutAcknowledgedChunkCount() throws {
        let objectID = VaultObjectID(rawValue: UUID())
        let revision = VaultRevision(objectID: objectID, logicalTime: 1, deviceID: "iphone")
        let current = try VaultMacPendingUpload(objectID: objectID, revision: revision,
            expectedRevision: nil, totalCiphertextBytes: 4, ciphertextDigest: Data(repeating: 1, count: 32))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(current)) as? [String: Any])
        // Simulate a pending-upload record persisted before this field
        // existed: it must decode as "nothing acknowledged yet" rather than
        // failing the whole pending-uploads file.
        object.removeValue(forKey: "acknowledgedChunkCount")
        let legacyJSON = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VaultMacPendingUpload.self, from: legacyJSON)
        XCTAssertEqual(decoded.acknowledgedChunkCount, 0)
        XCTAssertEqual(decoded.objectID, objectID)
        XCTAssertEqual(decoded.ciphertextDigest, current.ciphertextDigest)
    }
}
