import Foundation
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage
import VaultTestKit
import XCTest

final class VaultCryptoStorageTests: XCTestCase {
    private let objectID = VaultObjectID(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    private let revision = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    func testChunkEncryptionRoundTripsBoundariesAndEveryRange() throws {
        let root = try VaultRootKey(version: 1, key: Data(repeating: 7, count: 32))
        for length in [0, 1, 7, 8, 9, 16, 33] {
            let plaintext = Data((0..<length).map(UInt8.init))
            let cryptor = VaultChunkedCryptor(chunkSize: 8, vaultID: "tests", random: VaultTestRandomBytes(seed: UInt64(length + 1)))
            let frames = try cryptor.seal(plaintext, objectID: objectID, revision: revision, root: root)
            XCTAssertEqual(try cryptor.open(frames, objectID: objectID, revision: revision) { _ in root }, plaintext)
            for lower in 0...length {
                for upper in lower...length {
                    XCTAssertEqual(try cryptor.openRange(frames, range: lower..<upper, objectID: objectID, revision: revision) { _ in root }, plaintext[lower..<upper])
                }
            }
        }
    }

    func testChunkEncryptionRejectsTamperAndAADSwaps() throws {
        let root = try VaultRootKey(version: 3, key: Data(repeating: 9, count: 32))
        let cryptor = VaultChunkedCryptor(chunkSize: 4, vaultID: "alpha", random: VaultTestRandomBytes(seed: 44))
        let frames = try cryptor.seal(Data("confidential".utf8), objectID: objectID, revision: revision, root: root, role: .metadata)
        var tampered = frames; tampered[1][tampered[1].count - 1] ^= 1
        XCTAssertThrowsError(try cryptor.open(tampered, objectID: objectID, revision: revision, role: .metadata) { _ in root })
        XCTAssertThrowsError(try cryptor.open(frames, objectID: VaultObjectID(rawValue: UUID()), revision: revision, role: .metadata) { _ in root })
        XCTAssertThrowsError(try cryptor.open(frames, objectID: objectID, revision: UUID(), role: .metadata) { _ in root })
        XCTAssertThrowsError(try cryptor.open(frames, objectID: objectID, revision: revision, role: .index) { _ in root })
        let otherVault = VaultChunkedCryptor(chunkSize: 4, vaultID: "beta", random: VaultTestRandomBytes(seed: 44))
        XCTAssertThrowsError(try otherVault.open(frames, objectID: objectID, revision: revision, role: .metadata) { _ in root })
        var version = frames; version[1][0] = 2
        XCTAssertThrowsError(try cryptor.open(version, objectID: objectID, revision: revision, role: .metadata) { _ in root })
        XCTAssertEqual(Set(try frames.dropFirst().map { try VaultChunkEnvelope.decode($0, maximumBytes: 100).nonce }).count, frames.count - 1)
    }

    func testRootKeyLifecycleIsExplicitStrictAndConcurrent() throws {
        let descriptorGroup = "TEAM.com.hsanabria.luna.vault.keys"
        let store = InMemoryVaultKeyStore()
        let manager = VaultRootKeyManager(configuration: VaultCryptoConfiguration(keychainAccessGroup: descriptorGroup, vaultID: "strict"), store: store, random: VaultTestRandomBytes(seed: 2))
        XCTAssertThrowsError(try manager.loadRequired()) { XCTAssertEqual($0 as? VaultCryptoError, .keyUnavailable) }
        let created = try manager.createFirstRun(); XCTAssertEqual(created.version, 1)
        XCTAssertEqual(manager.descriptor.accessibility, .whenUnlocked); XCTAssertTrue(manager.descriptor.synchronizable); XCTAssertEqual(manager.descriptor.accessGroup, descriptorGroup)
        XCTAssertEqual(try manager.rotate().version, 2); XCTAssertEqual(try manager.key(version: 1), created)

        let raw = try XCTUnwrap(try store.data(for: manager.descriptor))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [[String: Any]])
        json[0]["fingerprint"] = "00"
        try store.setData(try JSONSerialization.data(withJSONObject: json), for: manager.descriptor)
        XCTAssertThrowsError(try manager.loadRequired()) { XCTAssertEqual($0 as? VaultCryptoError, .corruptRootKey) }

        let concurrentStore = InMemoryVaultKeyStore()
        let queue = DispatchQueue(label: "vault-key-race", attributes: .concurrent)
        let results = LockedResults()
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            queue.sync { let m=VaultRootKeyManager(configuration: VaultCryptoConfiguration(keychainAccessGroup: descriptorGroup, vaultID: "race"),store:concurrentStore,random:VaultTestRandomBytes(seed:UInt64(index+1)));if let key=try?m.createFirstRun(){results.append(key.fingerprint)} }
        }
        XCTAssertEqual(Set(results.values).count, 1)
    }

    func testStorageReopenTombstoneOrderingCacheAndJobs() throws {
        let directory = try VaultTemporaryDirectory(name: "stage2-storage")
        let configuration = VaultStorageConfiguration(cacheQuotaBytes: 2_000_000_000)
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let repo = try VaultRepository(configuration: configuration, testContainerURL: directory.url)
        let base = VaultObjectRecord(id: objectID, revision: revision, logicalTime: 10, size: 4, contentType: "text/plain", createdAt: now, updatedAt: now, accessedAt: now, deviceID: "phone")
        XCTAssertTrue(try repo.upsert(base)); XCTAssertEqual(try repo.integrityCheck(), "ok"); XCTAssertTrue(try repo.foreignKeysEnabled()); XCTAssertEqual(try repo.journalMode().lowercased(), "wal")
        _ = try repo.writeContent(Data("data".utf8), for: objectID)
        try repo.putCache(VaultCacheEntry(objectID: objectID, byteCount: 4, fullContent: true, lastAccessedAt: now, createdAt: now, pinned: false), now: now)
        XCTAssertTrue(try repo.tombstone(VaultTombstone(id: objectID, revision: UUID(), logicalTime: 11, deletedAt: now, deviceID: "phone")))
        XCTAssertNil(try repo.readContent(for: objectID)); XCTAssertTrue(try repo.cacheEntries().isEmpty)
        XCTAssertFalse(try repo.upsert(base), "stale content must not resurrect a tombstone")

        let reopened = try VaultRepository(configuration: configuration, testContainerURL: directory.url)
        XCTAssertTrue(try XCTUnwrap(reopened.object(objectID)).isTombstone)
        let job = VaultJob(kind: .index, idempotencyKey: "index-once")
        try reopened.enqueue(job); try reopened.enqueue(job)
        let claimed = try XCTUnwrap(reopened.claimNextJob(owner: "worker-a", now: now, leaseDuration: 5))
        XCTAssertEqual(claimed.attempts, 1); XCTAssertNil(try reopened.claimNextJob(owner: "worker-b", now: now))
        XCTAssertNotNil(try reopened.claimNextJob(owner: "worker-b", now: now.addingTimeInterval(6)), "expired lease is reclaimable after a crash")
    }

    func testEncryptedArtifactAcceptsOnlyAuthenticatedEnvelopeShape() throws {
        let root=try VaultRootKey(version:1,key:Data(repeating:5,count:32));let cryptor=VaultChunkedCryptor(chunkSize:16,vaultID:"artifact",random:VaultTestRandomBytes(seed:8));let frames=try cryptor.seal(Data("index".utf8),objectID:objectID,revision:revision,root:root,role:.index)
        let artifact=try VaultEncryptedArtifact(kind:.index,revision:revision,rootVersion:1,encryptedFrames:frames)
        let directory=try VaultTemporaryDirectory(name:"artifact");let repo=try VaultRepository(testContainerURL:directory.url);try repo.putEncryptedArtifact(artifact);XCTAssertEqual(try repo.encryptedArtifact(.index),artifact)
        XCTAssertThrowsError(try VaultEncryptedArtifact(kind:.manifest,revision:revision,rootVersion:1,encryptedFrames:frames))
    }

    func testMalformedFramesFailClosedBeforeDecrypt() throws {
        let root=try VaultRootKey(version:1,key:Data(repeating:3,count:32));let cryptor=VaultChunkedCryptor(chunkSize:4,vaultID:"strict",random:VaultTestRandomBytes(seed:19));let frames=try cryptor.seal(Data("123456789".utf8),objectID:objectID,revision:revision,root:root)
        XCTAssertThrowsError(try cryptor.open(Array(frames.dropLast()),objectID:objectID,revision:revision){_ in root})
        var reordered=frames;reordered.swapAt(1,2);XCTAssertThrowsError(try cryptor.open(reordered,objectID:objectID,revision:revision){_ in root})
        var truncated=frames;truncated[1].removeLast();XCTAssertThrowsError(try cryptor.open(truncated,objectID:objectID,revision:revision){_ in root})
        var wrap=frames;wrap[0].append(0);XCTAssertThrowsError(try cryptor.open(wrap,objectID:objectID,revision:revision){_ in root})
        XCTAssertThrowsError(try cryptor.openRange(frames,range:-1..<1,objectID:objectID,revision:revision){_ in root})
        XCTAssertThrowsError(try cryptor.openRange(frames,range:0..<10,objectID:objectID,revision:revision){_ in root})
    }

    func testTotalOrderingCacheExpiryAndSavesDatabaseIsolation() throws {
        let directory=try VaultTemporaryDirectory(name:"ordering-cache");let saves=directory.url.appendingPathComponent("saves.sqlite");let canary=Data("legacy-canary".utf8);try canary.write(to:saves)
        let repo=try VaultRepository(testContainerURL:directory.url);let now=Date(timeIntervalSinceReferenceDate:10_000)
        let low=VaultObjectRecord(id:objectID,revision:UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,logicalTime:5,size:3,createdAt:now,updatedAt:now,accessedAt:now,deviceID:"a")
        let high=VaultObjectRecord(id:objectID,revision:UUID(uuidString:"00000000-0000-0000-0000-000000000002")!,logicalTime:5,size:3,createdAt:now,updatedAt:now,accessedAt:now,deviceID:"b")
        XCTAssertTrue(try repo.upsert(low));XCTAssertTrue(try repo.upsert(high));XCTAssertFalse(try repo.upsert(low));XCTAssertEqual(try repo.object(objectID)?.deviceID,"b")
        _=try repo.writeContent(Data("old".utf8),for:objectID);try repo.putCache(VaultCacheEntry(objectID:objectID,byteCount:3,fullContent:true,lastAccessedAt:now.addingTimeInterval(-8*86400),createdAt:now,pinned:true),now:now);XCTAssertNotNil(try repo.readContent(for:objectID))
        try repo.setPinned(objectID,pinned:false);try repo.evictExpired(now:now);XCTAssertNil(try repo.readContent(for:objectID));XCTAssertTrue(try repo.cacheEntries().isEmpty)
        XCTAssertEqual(try Data(contentsOf:saves),canary,"Vault must never open or mutate saves.sqlite")
    }

    func testTwoConnectionsAtomicallyClaimOneJob() throws {
        let directory=try VaultTemporaryDirectory(name:"two-connection");let first=try VaultRepository(testContainerURL:directory.url);let second=try VaultRepository(testContainerURL:directory.url);let now=Date(timeIntervalSinceReferenceDate:42);try first.enqueue(VaultJob(kind:.download,createdAt:now,updatedAt:now,idempotencyKey:"one-claim"))
        let claims=LockedResults();DispatchQueue.concurrentPerform(iterations:2){index in let repo=index==0 ? first:second;if let _=try?repo.claimNextJob(owner:"worker-\(index)",now:now){claims.append("\(index)")}}
        XCTAssertEqual(claims.values.count,1)
    }
}

private final class LockedResults: @unchecked Sendable { private let lock=NSLock();private var storage=[String]();func append(_ value:String){lock.withLock{storage.append(value)}};var values:[String]{lock.withLock{storage}} }
