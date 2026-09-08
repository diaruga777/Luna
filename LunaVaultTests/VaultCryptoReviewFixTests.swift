import Foundation
import LunaVaultCrypto
import LunaVaultModels
import VaultTestKit
import XCTest

/// Regression pins for the 2026-08-31 crypto review pass: an empty-plaintext
/// object's sole chunk tag must be authenticated even though a full open asks
/// for the empty range `0..<0`, and a file seal must reject a repeated nonce
/// the same way the in-memory seal already does.
final class VaultCryptoReviewFixTests: XCTestCase {
    private let objectID = VaultObjectID(rawValue: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!)
    private let revision = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!

    func testEmptyPlaintextTamperedTagRejectedOnFullOpenAndAuthenticate() throws {
        let root = try VaultRootKey(version: 1, key: Data(repeating: 9, count: 32))
        let cryptor = VaultChunkedCryptor(chunkSize: 8, vaultID: "empty-tamper",
                                          random: VaultTestRandomBytes(seed: 201))
        var frames = try cryptor.seal(Data(), objectID: objectID, revision: revision, root: root)
        XCTAssertEqual(frames.count, 2, "an empty plaintext still has one chunk frame")
        frames[1][frames[1].count - 1] ^= 1

        XCTAssertThrowsError(
            try cryptor.open(frames, objectID: objectID, revision: revision) { _ in root },
            "a full open of an empty-plaintext object must still authenticate its one chunk")

        let tampered = try VaultAuthenticatedCiphertext(vaultID: "empty-tamper", kind: .content,
                                                         encryptedFrames: frames)
        XCTAssertThrowsError(try tampered.authenticate(rootKey: { _ in root }))
    }

    func testSealFileRejectsRepeatedNonceFromBrokenRandomSource() throws {
        let directory = try VaultTemporaryDirectory(name: "sealfile-nonce-reuse")
        defer { try? directory.cleanUp() }
        let plaintext = directory.url.appendingPathComponent("plain")
        let envelope = directory.url.appendingPathComponent("envelope.lvf")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: plaintext.path, contents: Data("more than one chunk".utf8)))
        let root = try VaultRootKey(version: 1, key: Data(repeating: 2, count: 32))

        XCTAssertThrowsError(try VaultAuthenticatedCiphertextFile.seal(
            plaintextURL: plaintext, fileURL: envelope, vaultID: "nonce-repeat",
            kind: .content, objectID: objectID, revision: revision, root: root,
            chunkSize: 4, random: StuckRandom()))
    }

    func testSealFileHandleOverloadRejectsRepeatedNonceFromBrokenRandomSource() throws {
        let directory = try VaultTemporaryDirectory(name: "sealfile-handle-nonce-reuse")
        defer { try? directory.cleanUp() }
        let plaintext = directory.url.appendingPathComponent("plain")
        let envelope = directory.url.appendingPathComponent("envelope.lvf")
        let bytes = Data("more than one chunk".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: plaintext.path, contents: bytes))
        let handle = try FileHandle(forReadingFrom: plaintext)
        defer { try? handle.close() }
        let root = try VaultRootKey(version: 1, key: Data(repeating: 7, count: 32))

        XCTAssertThrowsError(try VaultAuthenticatedCiphertextFile.seal(
            plaintextHandle: handle, plaintextByteCount: UInt64(bytes.count), fileURL: envelope,
            vaultID: "nonce-repeat-handle", kind: .content, objectID: objectID, revision: revision,
            root: root, chunkSize: 4, random: StuckRandom()))
    }
}

/// Always returns the same bytes, standing in for a stuck hardware RNG.
private struct StuckRandom: VaultRandomBytesGenerating {
    func bytes(count: Int) throws -> Data { Data(repeating: 1, count: count) }
}
