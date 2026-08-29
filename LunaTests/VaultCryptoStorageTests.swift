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

        let serviceManager=VaultRootKeyManager(configuration:VaultCryptoConfiguration(keychainAccessGroup:descriptorGroup,vaultID:"service",keychainService:"example.custom.vault.keys"),store:InMemoryVaultKeyStore(),random:VaultTestRandomBytes(seed:4),lifecycleLockURL:nil)
        XCTAssertEqual(serviceManager.descriptor.service,"example.custom.vault.keys")
        let simulatedHosts=["com.example.luna.vault","com.example.luna"]
        let stableServices=simulatedHosts.map{VaultCryptoConfiguration(keychainAccessGroup:descriptorGroup,appGroupID:"group.com.example.luna",hostBundleIdentifier:$0).keychainService}
        XCTAssertEqual(Set(stableServices),["com.example.luna.vault.keys"])
        let maxStore=InMemoryVaultKeyStore();let maxManager=VaultRootKeyManager(configuration:VaultCryptoConfiguration(keychainAccessGroup:descriptorGroup,vaultID:"max"),store:maxStore,random:VaultTestRandomBytes(seed:5),lifecycleLockURL:nil);let maxKey=try VaultRootKey(version:UInt32.max,key:Data(repeating:2,count:32));try maxStore.setData(try JSONEncoder().encode([maxKey]),for:maxManager.descriptor);XCTAssertThrowsError(try maxManager.rotate())
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
        let artifact=try VaultEncryptedArtifact(kind:.index,vaultID:"artifact",revision:revision,rootVersion:1,encryptedFrames:frames)
        let directory=try VaultTemporaryDirectory(name:"artifact");let repo=try VaultRepository(configuration:VaultStorageConfiguration(vaultID:"artifact"),testContainerURL:directory.url);try repo.putEncryptedArtifact(artifact);XCTAssertEqual(try repo.encryptedArtifact(.index),artifact)
        XCTAssertThrowsError(try VaultEncryptedArtifact(kind:.manifest,vaultID:"artifact",revision:revision,rootVersion:1,encryptedFrames:frames))
    }

    func testMalformedFramesFailClosedBeforeDecrypt() throws {
        let root=try VaultRootKey(version:1,key:Data(repeating:3,count:32));let cryptor=VaultChunkedCryptor(chunkSize:4,vaultID:"strict",random:VaultTestRandomBytes(seed:19));let frames=try cryptor.seal(Data("123456789".utf8),objectID:objectID,revision:revision,root:root)
        XCTAssertThrowsError(try cryptor.open(Array(frames.dropLast()),objectID:objectID,revision:revision){_ in root})
        var reordered=frames;reordered.swapAt(1,2);XCTAssertThrowsError(try cryptor.open(reordered,objectID:objectID,revision:revision){_ in root})
        var truncated=frames;truncated[1].removeLast();XCTAssertThrowsError(try cryptor.open(truncated,objectID:objectID,revision:revision){_ in root})
        var wrap=frames;wrap[0].append(0);XCTAssertThrowsError(try cryptor.open(wrap,objectID:objectID,revision:revision){_ in root})
        XCTAssertThrowsError(try cryptor.openRange(frames,range:-1..<1,objectID:objectID,revision:revision){_ in root})
        XCTAssertThrowsError(try cryptor.openRange(frames,range:0..<10,objectID:objectID,revision:revision){_ in root})
        var emptyTamper=frames;emptyTamper[1][emptyTamper[1].count-1]^=1;XCTAssertThrowsError(try cryptor.openRange(emptyTamper,range:0..<0,objectID:objectID,revision:revision){_ in root})
        let repeating=VaultChunkedCryptor(chunkSize:4,vaultID:"nonce-repeat",random:RepeatingRandom());XCTAssertThrowsError(try repeating.seal(Data("more than one chunk".utf8),objectID:objectID,revision:revision,root:root))
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

    func testStaleTombstoneIsNoOpAndNewerTombstoneCleans() throws {
        let directory=try VaultTemporaryDirectory(name:"tombstone-order");let repo=try VaultRepository(testContainerURL:directory.url);let now=Date(timeIntervalSinceReferenceDate:90);let objectRevision=UUID(uuidString:"10000000-0000-0000-0000-000000000000")!;let record=VaultObjectRecord(id:objectID,revision:objectRevision,logicalTime:10,size:4,createdAt:now,updatedAt:now,accessedAt:now,deviceID:"phone");XCTAssertTrue(try repo.upsert(record));_=try repo.writeContent(Data("keep".utf8),for:objectID);try repo.putCache(VaultCacheEntry(objectID:objectID,byteCount:4,fullContent:true,lastAccessedAt:now,createdAt:now),now:now)
        XCTAssertFalse(try repo.tombstone(VaultTombstone(id:objectID,revision:UUID(),logicalTime:9,deletedAt:now,deviceID:"phone")));XCTAssertNotNil(try repo.readContent(for:objectID));XCTAssertEqual(try repo.cacheEntries().count,1)
        XCTAssertFalse(try repo.tombstone(VaultTombstone(id:objectID,revision:objectRevision,logicalTime:10,deletedAt:now,deviceID:"phone")));XCTAssertNotNil(try repo.readContent(for:objectID))
        XCTAssertTrue(try repo.tombstone(VaultTombstone(id:objectID,revision:UUID(),logicalTime:11,deletedAt:now,deviceID:"phone")));XCTAssertNil(try repo.readContent(for:objectID));XCTAssertTrue(try repo.cacheEntries().isEmpty)
    }

    func testReclaimedJobRejectsStaleOwnerTransition() throws {
        let directory=try VaultTemporaryDirectory(name:"job-reclaim");let repo=try VaultRepository(testContainerURL:directory.url);let now=Date(timeIntervalSinceReferenceDate:200);let job=VaultJob(kind:.upload,createdAt:now,updatedAt:now);try repo.enqueue(job);let original=try XCTUnwrap(repo.claimNextJob(owner:"a",now:now,leaseDuration:5));let reclaimed=try XCTUnwrap(repo.claimNextJob(owner:"b",now:now.addingTimeInterval(6),leaseDuration:10));XCTAssertEqual(reclaimed.leaseOwner,"b");XCTAssertNotEqual(original.leaseToken,reclaimed.leaseToken)
        XCTAssertThrowsError(try repo.transitionJob(id:job.id,leaseToken:original.leaseToken,state:.succeeded,now:now.addingTimeInterval(7)));XCTAssertNoThrow(try repo.transitionJob(id:job.id,leaseToken:reclaimed.leaseToken,state:.succeeded,now:now.addingTimeInterval(7)))
    }

    func testExpiredLeaseCannotBeRevivedByHeartbeat() throws {
        let directory=try VaultTemporaryDirectory(name:"heartbeat-expiry"),now=Date(timeIntervalSinceReferenceDate:250);let repo=try VaultRepository(testContainerURL:directory.url);let job=VaultJob(kind:.download,createdAt:now,updatedAt:now);try repo.enqueue(job);let expired=try XCTUnwrap(repo.claimNextJob(owner:"expired",now:now,leaseDuration:5))
        XCTAssertThrowsError(try repo.heartbeatJob(id:job.id,leaseToken:try XCTUnwrap(expired.leaseToken),now:now.addingTimeInterval(5),leaseDuration:30))
        XCTAssertEqual(try repo.claimNextJob(owner:"replacement",now:now.addingTimeInterval(5),leaseDuration:30)?.leaseOwner,"replacement")
    }

    func testCacheDowngradeAndStartupRepair() throws {
        let directory=try VaultTemporaryDirectory(name:"repair"),protection=SelectiveProtection();let now=Date(timeIntervalSinceReferenceDate:300);let repo=try VaultRepository(testContainerURL:directory.url,protectionApplier:protection);let record=VaultObjectRecord(id:objectID,revision:revision,logicalTime:1,size:3,createdAt:now,updatedAt:now,accessedAt:now);_=try repo.upsert(record);_=try repo.writeContent(Data("old".utf8),for:objectID);try repo.putCache(VaultCacheEntry(objectID:objectID,byteCount:3,fullContent:true,lastAccessedAt:now,createdAt:now),now:now);try repo.putCache(VaultCacheEntry(objectID:objectID,byteCount:1,fullContent:false,lastAccessedAt:now,createdAt:now),now:now);XCTAssertNil(try repo.readContent(for:objectID));XCTAssertFalse(try XCTUnwrap(repo.cacheEntries().first).fullContent)
        _=try repo.writeContent(Data("new".utf8),for:objectID);let objectDir=repo.contentDirectory.appendingPathComponent(objectID.rawValue.uuidString),content=objectDir.appendingPathComponent("content"),generation=objectDir.appendingPathComponent(".content-generation"),previous=objectDir.appendingPathComponent(".previous"),previousGeneration=objectDir.appendingPathComponent(".previous-generation"),staging=objectDir.appendingPathComponent(".staging-crash");try FileManager.default.moveItem(at:content,to:previous);try FileManager.default.moveItem(at:generation,to:previousGeneration);try Data("partial".utf8).write(to:staging);let reopened=try VaultRepository(testContainerURL:directory.url,protectionApplier:protection);XCTAssertEqual(try reopened.readContent(for:objectID),Data("new".utf8));XCTAssertFalse(FileManager.default.fileExists(atPath:staging.path));XCTAssertFalse(FileManager.default.fileExists(atPath:previous.path))
    }

    func testDurableCleanupAndProtectionFailure() throws {
        let directory=try VaultTemporaryDirectory(name:"cleanup-marker");let manager=ToggleFailFileManager();let now=Date(timeIntervalSinceReferenceDate:400);let repo=try VaultRepository(testContainerURL:directory.url,fileManager:manager);let record=VaultObjectRecord(id:objectID,revision:revision,logicalTime:1,size:3,createdAt:now,updatedAt:now,accessedAt:now);_=try repo.upsert(record);_=try repo.writeContent(Data("old".utf8),for:objectID);manager.failRemoval=true;XCTAssertThrowsError(try repo.tombstone(VaultTombstone(id:objectID,revision:UUID(),logicalTime:2,deletedAt:now)));manager.failRemoval=false;let reopened=try VaultRepository(testContainerURL:directory.url);XCTAssertNil(try reopened.readContent(for:objectID));XCTAssertTrue(try XCTUnwrap(reopened.object(objectID)).isTombstone)
        let protected=try VaultTemporaryDirectory(name:"protection-failure");XCTAssertThrowsError(try VaultRepository(testContainerURL:protected.url,protectionApplier:FailingProtection()))
    }

    func testObsoleteCleanupMarkerCannotDeleteNewGeneration() throws {
        let directory=try VaultTemporaryDirectory(name:"cleanup-generation"),manager=ToggleFailFileManager(),protection=SelectiveProtection(),now=Date(timeIntervalSinceReferenceDate:450);let repo=try VaultRepository(testContainerURL:directory.url,fileManager:manager,protectionApplier:protection)
        let old=VaultObjectRecord(id:objectID,revision:revision,logicalTime:1,size:3,createdAt:now,updatedAt:now,accessedAt:now);XCTAssertTrue(try repo.upsert(old));_=try repo.writeContent(Data("old".utf8),for:objectID)
        manager.failRemoval=true;XCTAssertThrowsError(try repo.tombstone(VaultTombstone(id:objectID,revision:UUID(),logicalTime:2,deletedAt:now)));manager.failRemoval=false
        let newRevision=UUID(),new=VaultObjectRecord(id:objectID,revision:newRevision,logicalTime:3,size:3,createdAt:now,updatedAt:now,accessedAt:now);XCTAssertTrue(try repo.upsert(new));_=try repo.writeContent(Data("new".utf8),for:objectID)
        let reopened=try VaultRepository(testContainerURL:directory.url,protectionApplier:protection);XCTAssertEqual(try reopened.readContent(for:objectID),Data("new".utf8));let reopenedAgain=try VaultRepository(testContainerURL:directory.url,protectionApplier:protection);XCTAssertEqual(try reopenedAgain.readContent(for:objectID),Data("new".utf8))
    }

    func testStagingProtectionFailurePreservesPreviousContent() throws {
        let directory=try VaultTemporaryDirectory(name:"protect-staging"),applier=SelectiveProtection(),now=Date(timeIntervalSinceReferenceDate:475);let repo=try VaultRepository(testContainerURL:directory.url,protectionApplier:applier);let record=VaultObjectRecord(id:objectID,revision:revision,logicalTime:1,size:3,createdAt:now,updatedAt:now,accessedAt:now);XCTAssertTrue(try repo.upsert(record));_=try repo.writeContent(Data("old".utf8),for:objectID)
        applier.failStaging=true;XCTAssertThrowsError(try repo.writeContent(Data("new".utf8),for:objectID));XCTAssertEqual(try repo.readContent(for:objectID),Data("old".utf8));applier.failStaging=false;let reopened=try VaultRepository(testContainerURL:directory.url,protectionApplier:applier);XCTAssertEqual(try reopened.readContent(for:objectID),Data("old".utf8))
    }

    func testStartupRejectsUnprotectedInstalledFinalAndRestoresPrevious() throws {
        let directory=try VaultTemporaryDirectory(name:"unprotected-crash"),applier=SyntheticCrashProtection(),now=Date(timeIntervalSinceReferenceDate:480);let repo=try VaultRepository(testContainerURL:directory.url,protectionApplier:applier);let record=VaultObjectRecord(id:objectID,revision:revision,logicalTime:1,size:3,createdAt:now,updatedAt:now,accessedAt:now);XCTAssertTrue(try repo.upsert(record));_=try repo.writeContent(Data("old".utf8),for:objectID)
        let dir=repo.contentDirectory.appendingPathComponent(objectID.rawValue.uuidString),final=dir.appendingPathComponent("content"),generation=dir.appendingPathComponent(".content-generation"),previous=dir.appendingPathComponent(".previous"),previousGeneration=dir.appendingPathComponent(".previous-generation"),staging=dir.appendingPathComponent(".staging-crash")
        try FileManager.default.moveItem(at:final,to:previous);try FileManager.default.moveItem(at:generation,to:previousGeneration);try Data("unprotected-new".utf8).write(to:final);try Data(contentsOf:previousGeneration).write(to:generation);try Data("partial".utf8).write(to:staging);applier.unprotectedPath=final.path
        let reopened=try VaultRepository(testContainerURL:directory.url,protectionApplier:applier);XCTAssertEqual(try reopened.readContent(for:objectID),Data("old".utf8));XCTAssertFalse(FileManager.default.fileExists(atPath:staging.path));XCTAssertFalse(FileManager.default.fileExists(atPath:previous.path))
    }

    func testVaultShareSourceHasNoRootKeyAuthorizationBoundary() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent(),entitlementsURL=root.appendingPathComponent("LunaVaultShare/LunaVaultShare.entitlements"),infoURL=root.appendingPathComponent("LunaVaultShare/Info.plist"),sourceURL=root.appendingPathComponent("LunaVaultShare/VaultShareViewController.swift")
        let entitlements=try XCTUnwrap(try PropertyListSerialization.propertyList(from:Data(contentsOf:entitlementsURL),format:nil) as? [String:Any]),info=try XCTUnwrap(try PropertyListSerialization.propertyList(from:Data(contentsOf:infoURL),format:nil) as? [String:Any]),source=try String(contentsOf:sourceURL,encoding:.utf8)
        XCTAssertNil(entitlements["keychain-access-groups"]);XCTAssertNil(info["LunaVaultKeychainAccessGroup"]);XCTAssertFalse(source.contains("LunaVaultCrypto"));XCTAssertFalse(source.contains("VaultCryptoConfiguration"));XCTAssertFalse(source.contains("VaultRootKeyManager"))
    }

    func testConcurrentFirstOpenAndMixedArtifacts() throws {
        let directory=try VaultTemporaryDirectory(name:"first-open");let opens=LockedResults();DispatchQueue.concurrentPerform(iterations:6){_ in do{let repo=try VaultRepository(testContainerURL:directory.url);opens.append(try repo.integrityCheck())}catch{opens.append("error:\(error)")}};XCTAssertEqual(opens.values,[String](repeating:"ok",count:6),"\(opens.values)")
        let root=try VaultRootKey(version:1,key:Data(repeating:6,count:32));let cryptor=VaultChunkedCryptor(chunkSize:4,vaultID:"mix",random:VaultTestRandomBytes(seed:30));let first=try cryptor.seal(Data("abcdefgh".utf8),objectID:objectID,revision:revision,root:root,role:.index);let other=try cryptor.seal(Data("ABCDEFGH".utf8),objectID:VaultObjectID(rawValue:UUID()),revision:revision,root:root,role:.index);var mixed=first;mixed[2]=other[2];XCTAssertThrowsError(try VaultEncryptedArtifact(kind:.index,vaultID:"mix",revision:revision,rootVersion:1,encryptedFrames:mixed));XCTAssertThrowsError(try VaultEncryptedArtifact(kind:.index,vaultID:"wrong",revision:revision,rootVersion:1,encryptedFrames:first))
    }

    func testExtractionArtifactAndLeaseLifecycleSurviveRestart() throws {
        let directory = try VaultTemporaryDirectory(name: "extraction-lifecycle")
        let now = Date(timeIntervalSinceReferenceDate: 900)
        let repo = try VaultRepository(testContainerURL: directory.url)
        let record = VaultObjectRecord(id: objectID, revision: revision, logicalTime: 1, size: 4,
                                       createdAt: now, updatedAt: now, accessedAt: now)
        XCTAssertTrue(try repo.upsert(record))
        let payload = Data("artifact".utf8)
        try repo.putExtractionArtifact(payload, objectID: objectID, revision: revision, modelVersion: "v2")
        XCTAssertEqual(try repo.extractionArtifact(objectID: objectID, revision: revision, modelVersion: "v2"), payload)
        XCTAssertNil(try repo.extractionArtifact(objectID: objectID, revision: revision, modelVersion: "other"))

        let lease = try repo.beginExtractionJob(objectID: objectID, revision: revision, modelVersion: "v2",
                                                owner: "worker-a", now: now, leaseDuration: 30)
        XCTAssertThrowsError(try repo.beginExtractionJob(objectID: objectID, revision: revision,
                                                         modelVersion: "v2", owner: "worker-b",
                                                         now: now.addingTimeInterval(1), leaseDuration: 30))
        try repo.transitionExtractionJob(lease, to: .succeeded, error: nil, retryAt: nil,
                                         now: now.addingTimeInterval(2))
        try repo.removeExtractionArtifacts(for: objectID)
        let reopened = try VaultRepository(testContainerURL: directory.url)
        XCTAssertNil(try reopened.extractionArtifact(objectID: objectID, revision: revision, modelVersion: "v2"))
        let retry = try reopened.beginExtractionJob(objectID: objectID, revision: revision,
                                                    modelVersion: "v2", owner: "worker-c",
                                                    now: now.addingTimeInterval(3), leaseDuration: 30)
        try reopened.transitionExtractionJob(retry, to: .failed, error: "fixture", retryAt: nil,
                                             now: now.addingTimeInterval(4))
    }
}

private final class LockedResults: @unchecked Sendable { private let lock=NSLock();private var storage=[String]();func append(_ value:String){lock.withLock{storage.append(value)}};var values:[String]{lock.withLock{storage}} }
private struct RepeatingRandom: VaultRandomBytesGenerating { func bytes(count:Int)throws->Data{Data(repeating:1,count:count)} }
private struct FailingProtection: VaultFileProtectionApplying { func apply(to url:URL)throws{throw NSError(domain:"protection",code:1)};func hasRequiredProtection(at url:URL)throws->Bool{false} }
private final class SelectiveProtection: VaultFileProtectionApplying,@unchecked Sendable { var failStaging=false;func apply(to url:URL)throws{if failStaging&&url.lastPathComponent.hasPrefix(".staging-"){throw NSError(domain:"protection-staging",code:1)}};func hasRequiredProtection(at url:URL)throws->Bool{true} }
private final class SyntheticCrashProtection: VaultFileProtectionApplying,@unchecked Sendable {
    var unprotectedPath:String?
    private var protectedInodes=Set<Int64>()
    func apply(to url:URL)throws{
        if let inode=(try?FileManager.default.attributesOfItem(atPath:url.path)[.systemFileNumber] as? NSNumber)?.int64Value{protectedInodes.insert(inode)}
    }
    func hasRequiredProtection(at url:URL)throws->Bool{
        guard let inode=(try?FileManager.default.attributesOfItem(atPath:url.path)[.systemFileNumber] as? NSNumber)?.int64Value else{return false}
        return url.path != unprotectedPath || protectedInodes.contains(inode)
    }
}
private final class ToggleFailFileManager: FileManager, @unchecked Sendable { var failRemoval=false;override func removeItem(at URL:URL)throws{if failRemoval && URL.path.contains("VaultObjects"){throw NSError(domain:"remove",code:1)};try super.removeItem(at:URL)} }
