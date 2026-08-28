import Foundation
import LunaVaultCrypto
import LunaVaultEmbeddings
import LunaVaultModels
import LunaVaultSearch
import LunaVaultStorage
import VaultTestKit
import XCTest
#if canImport(Darwin)
import Darwin
#endif

final class VaultSearchTests: XCTestCase {
    private func makeIndex(_ name: String = "search") throws -> (VaultSearchIndex, VaultTemporaryDirectory, RecordingSearchProtection) {
        let directory = try VaultTemporaryDirectory(name: name)
        let protection = RecordingSearchProtection()
        // Keep the fixture owner alive even when a test intentionally ignores the
        // tuple's directory element. Its deinit removes the SQLite files.
        addTeardownBlock { _ = directory }
        return (try VaultSearchIndex(databaseURL: directory.url.appendingPathComponent("vault-index.sqlite"), protectionApplier: protection), directory, protection)
    }
    private func id(_ value: Int) -> VaultObjectID { VaultObjectID(rawValue: UUID(uuidString: String(format:"00000000-0000-0000-0000-%012d",value))!) }
    private func revision(_ value: Int) -> UUID { UUID(uuidString:String(format:"10000000-0000-0000-0000-%012d",value))! }
    private func doc(_ value:Int, filename:String="file.txt", body:String="", ocr:String="", transcript:String="", vector:[Float]?=nil, logical:Int64?=nil, device:String="phone") -> VaultIndexedDocument {
        let date=Date(timeIntervalSinceReferenceDate:TimeInterval(value));return VaultIndexedDocument(id:id(value),revision:revision(value),logicalTime:logical ?? Int64(value),deviceID:device,filename:filename,bodyText:body,ocrText:ocr,transcriptText:transcript,createdAt:date,updatedAt:date,accessedAt:date,embedding:vector.map{VaultEmbedding(values:$0,modelVersion:"v1")})
    }

    func testGoldenHybridRankingAndMatchedSnippetProvenance() throws {
        let(index,_,_)=try makeIndex();try index.upsert(doc(1,filename:"project.txt",body:"ordinary",vector:[0,1]));try index.upsert(doc(2,filename:"other.txt",body:"project body",vector:[1,0]));try index.upsert(doc(3,filename:"scan.png",ocr:"project receipt",vector:[0.9,0.1]));try index.upsert(doc(4,filename:"movie.mov",transcript:"project spoken at 03:21",vector:[0.8,0.2]))
        let result=try index.search("project",embedding:VaultEmbedding(values:[1,0],modelVersion:"v1"));XCTAssertEqual(result.first?.filename,"project.txt","exact filename dominates");let ocr=try XCTUnwrap(result.first{$0.filename=="scan.png"});XCTAssertEqual(ocr.snippetSource,.ocr);XCTAssertTrue(ocr.snippet.contains("receipt"));let transcript=try XCTUnwrap(result.first{$0.filename=="movie.mov"});XCTAssertEqual(transcript.snippetSource,.transcript);XCTAssertTrue(transcript.snippet.contains("03:21"))
    }

    func testTotalRevisionOrderingUnknownDeleteAndNoResurrection() throws {
        let(index,_,_)=try makeIndex();let object=id(9);let deleteStamp=VaultIndexRevision(logicalTime:10,deviceID:"b",revision:revision(10));XCTAssertTrue(try index.delete(object,stamp:deleteStamp));XCTAssertTrue(try XCTUnwrap(index.document(object)).isTombstone)
        let stale=VaultIndexedDocument(id:object,revision:revision(11),logicalTime:10,deviceID:"a",filename:"stale",createdAt:Date(),updatedAt:Date(),accessedAt:Date());XCTAssertFalse(try index.upsert(stale));XCTAssertFalse(try index.delete(object,stamp:deleteStamp),"equal delete is idempotent");let fresh=VaultIndexedDocument(id:object,revision:revision(12),logicalTime:11,deviceID:"a",filename:"fresh",bodyText:"visible",createdAt:Date(),updatedAt:Date(),accessedAt:Date());XCTAssertTrue(try index.upsert(fresh));XCTAssertEqual(try index.search("visible").count,1)
    }

    func testDeleteFiltersEverySurfaceAndCleansAliases() throws {
        let(index,_,_)=try makeIndex();try index.upsert(doc(1,body:"needle",vector:[1,0]));let group=try index.createGroup(label:"Pinned");let alias=try index.addManualMembership(objectID:id(1),toGroup:group.id,modelVersion:"v1");let snapshot=try index.createQueryGroup(query:"needle",members:[VaultObjectID(rawValue:alias.id)]);XCTAssertEqual(snapshot.memberIDs,[id(1)]);XCTAssertTrue(try index.delete(id(1),stamp:VaultIndexRevision(logicalTime:99,deviceID:"phone")));XCTAssertTrue(try index.search("needle",embedding:VaultEmbedding(values:[1,0],modelVersion:"v1")).isEmpty);XCTAssertTrue(try index.groups().first{$0.id==group.id}?.memberIDs.isEmpty == true);XCTAssertTrue(try index.queryGroup(snapshot.id)?.memberIDs.isEmpty == true);XCTAssertTrue(try index.aliases(for:id(1)).isEmpty)
    }

    func testModelDimensionAndMalformedValuesFailClosed() throws {
        let(index,_,_)=try makeIndex();try index.upsert(doc(1,vector:[1,0]));XCTAssertThrowsError(try index.upsert(VaultIndexedDocument(id:id(2),revision:revision(2),logicalTime:2,deviceID:"p",filename:"bad",createdAt:Date(),updatedAt:Date(),accessedAt:Date(),embedding:VaultEmbedding(values:[1,0,0],modelVersion:"v1")))){XCTAssertEqual($0 as? VaultSearchError,.dimensionMismatch(expected:2,actual:3))};XCTAssertThrowsError(try index.upsert(VaultIndexedDocument(id:id(3),revision:revision(3),logicalTime:3,deviceID:"p",filename:"nan",createdAt:Date(),updatedAt:Date(),accessedAt:Date(),embedding:VaultEmbedding(values:[.nan,0],modelVersion:"v2"))));XCTAssertEqual(try index.cosineSearch(VaultEmbedding(values:[1,0],modelVersion:"v1")).first?.0,id(1))
    }

    func testAliasMembershipIsIdempotentCanonicalAndAvailableEverywhere() throws {
        let(index,_,_)=try makeIndex();try index.upsert(doc(1,filename:"source",vector:[1,0]));let group=try index.createGroup(label:"Tax records");let first=try index.addManualMembership(objectID:id(1),toGroup:group.id,modelVersion:"v1"),second=try index.addManualMembership(objectID:id(1),toGroup:group.id,modelVersion:"v1");XCTAssertEqual(first.id,second.id);XCTAssertEqual(try index.resolveCanonical(VaultObjectID(rawValue:first.id)),id(1));XCTAssertEqual(try index.groups().first{$0.id==group.id}?.memberIDs,[id(1)]);let lexical=try index.search("Tax records");XCTAssertEqual(lexical.count,1);XCTAssertEqual(lexical.first?.canonicalObjectID,id(1));XCTAssertTrue(lexical.first?.isSymbolicAlias == true);let semantic=try index.search("unrelated",embedding:VaultEmbedding(values:[1,0],modelVersion:"v1"));XCTAssertEqual(Set(semantic.map(\.canonicalObjectID)),[id(1)]);XCTAssertEqual(semantic.count,1)
    }

    func testVectorAndHybridSearchDeduplicateCanonicalObjectAndPreferHigherScoringAlias() throws {
        let(index,_,_)=try makeIndex();try index.upsert(doc(1,filename:"source",body:"source",vector:[1,0]));try index.upsert(doc(2,filename:"other",body:"other",vector:[0,1]))
        let group=try index.createGroup(label:"Tax records",members:[id(2)]);let alias=try index.addManualMembership(objectID:id(1),toGroup:group.id,modelVersion:"v1")
        let query=alias.embedding
        let vector=try index.cosineSearch(query,limit:10);XCTAssertEqual(Set(vector.map { $0.0 }).count,vector.count);XCTAssertEqual(vector.first?.0, VaultObjectID(rawValue:alias.id))
        let hybrid=try index.search("no lexical match",embedding:query,limit:10);let canonicalHits=hybrid.filter{$0.canonicalObjectID == id(1)};XCTAssertEqual(canonicalHits.count,1);XCTAssertEqual(canonicalHits.first?.objectID,VaultObjectID(rawValue:alias.id));XCTAssertEqual(canonicalHits.first?.canonicalObjectID,id(1));XCTAssertTrue(canonicalHits.first?.isSymbolicAlias == true);XCTAssertTrue(canonicalHits.first?.matchedFields.contains("vector") == true)
        let label=try index.search("Tax records");XCTAssertEqual(label.count,1);XCTAssertEqual(label.first?.objectID,VaultObjectID(rawValue:alias.id));XCTAssertTrue(label.first?.isSymbolicAlias == true)
    }

    func testSnapshotsRejectDuplicatesAndTombstonesWhileLiveGroupsRefresh() throws {
        let(index,_,_)=try makeIndex();try index.upsert(doc(1,body:"mars"));XCTAssertThrowsError(try index.createQueryGroup(query:"mars",members:[id(1),id(1)]));let snapshot=try index.createQueryGroup(query:"mars",members:[id(1)]);let live=try index.createQueryGroup(query:"mars",members:[],live:true);try index.upsert(doc(2,body:"mars"));XCTAssertEqual(try index.queryGroup(snapshot.id)?.memberIDs,[id(1)]);XCTAssertEqual(Set(try XCTUnwrap(index.queryGroup(live.id)).memberIDs),[id(1),id(2)]);try index.delete(id(1),stamp:VaultIndexRevision(logicalTime:50,deviceID:"p"));XCTAssertEqual(try index.queryGroup(snapshot.id)?.memberIDs,[]);XCTAssertThrowsError(try index.createQueryGroup(query:"mars",members:[id(1)]))
    }

    func testPunctuationLimitsReopenAndFTSOrderAreSafe() throws {
        let(index,directory,protection)=try makeIndex();try index.upsert(doc(1,filename:"2026-report.pdf",body:"budget forecast"));try index.upsert(doc(2,filename:"other.pdf",body:"budget"));XCTAssertNoThrow(try index.search("?! budget — 2026"));XCTAssertThrowsError(try index.search("budget",limit:0));XCTAssertEqual(try index.search("budget forecast").first?.objectID,id(1));XCTAssertTrue(protection.paths.contains{ $0.hasSuffix("vault-index.sqlite") });let reopened=try VaultSearchIndex(databaseURL:directory.url.appendingPathComponent("vault-index.sqlite"),protectionApplier:protection);XCTAssertEqual(try reopened.search("budget").count,2);XCTAssertEqual(try reopened.integrityCheck(),"ok")
    }

    func testConcurrentConnectionsUseBusyRetry() throws {
        let directory=try VaultTemporaryDirectory(name:"search-concurrent"),protection=RecordingSearchProtection(),url=directory.url.appendingPathComponent("vault-index.sqlite");let first=try VaultSearchIndex(databaseURL:url,protectionApplier:protection),second=try VaultSearchIndex(databaseURL:url,protectionApplier:protection);let failures=LockedSearchFailures();DispatchQueue.concurrentPerform(iterations:40){value in do{_ = try (value.isMultiple(of:2) ? first:second).upsert(self.doc(value+1,body:"concurrent"))}catch{failures.append(error)}};XCTAssertTrue(failures.values.isEmpty);XCTAssertEqual(try first.search("concurrent",limit:100).count,40);XCTAssertEqual(try first.integrityCheck(),"ok")
    }

    func testEncryptedExportRestoreNeverReturnsPlaintextArtifact() throws {
        let(index,directory,protection)=try makeIndex("search-export");try index.upsert(doc(1,body:"highly confidential phrase",vector:[1,0]));let root=try VaultRootKey(version:1,key:Data(repeating:7,count:32)),cryptor=VaultChunkedCryptor(chunkSize:128,vaultID:"search-tests",random:VaultTestRandomBytes(seed:99)),object=id(500),revision=revision(500);let artifact=try index.encryptedExport(cryptor:cryptor,root:root,objectID:object,revision:revision);XCTAssertFalse(artifact.encryptedFrames.contains{String(data:$0,encoding:.utf8)?.contains("highly confidential") == true});let restored=directory.url.appendingPathComponent("restored.sqlite");try VaultSearchIndex.restoreEncryptedExport(artifact,cryptor:cryptor,to:restored,protectionApplier:protection){_ in root};let reopened=try VaultSearchIndex(databaseURL:restored,protectionApplier:protection);XCTAssertEqual(try reopened.search("confidential").count,1)
    }

    func testEncryptedExportFailsClosedWhenWALCheckpointIsBusy() throws {
        let(index,_,_)=try makeIndex("search-export-busy");let root=try VaultRootKey(version:1,key:Data(repeating:7,count:32)),cryptor=VaultChunkedCryptor(vaultID:"search-tests",random:VaultTestRandomBytes(seed:99))
        index.walCheckpointOverride={ 5 /* SQLITE_BUSY */ }
        XCTAssertThrowsError(try index.encryptedExport(cryptor:cryptor,root:root,objectID:id(500),revision:revision(500))) { error in
            guard case let VaultSearchError.sqlite(message)=error else { return XCTFail("unexpected error: \(error)") }
            XCTAssertTrue(message.contains("WAL checkpoint failed"))
        }
    }

    func testHundredThousandSQLiteRecordsPerformanceNightly() throws {
        guard ProcessInfo.processInfo.environment["LUNA_VAULT_PERFORMANCE"] == "1" else { throw XCTSkip("set LUNA_VAULT_PERFORMANCE=1 for the 100k SQLite benchmark") }
        let(index,directory,_)=try makeIndex("search-performance-100k");let documents=(1...100_000).map{value in doc(value,filename:"document-\(value).txt",body:"benchmark payload \(value)")};let start=ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(try index.upsertBatch(documents),100_000)
        let buildSeconds=ProcessInfo.processInfo.systemUptime-start
        var queryDurations:[Double]=[];queryDurations.reserveCapacity(40)
        for value in stride(from:1,through:100_000,by:2_500) { let queryStart=ProcessInfo.processInfo.systemUptime;XCTAssertEqual(try index.search("document-\(value)").count,1);queryDurations.append(ProcessInfo.processInfo.systemUptime-queryStart) }
        let sorted=queryDurations.sorted();let p50=sorted[sorted.count/2],p95=sorted[Int(Double(sorted.count-1)*0.95)]
        let dbBytes=["","-wal","-shm"].compactMap{try? FileManager.default.attributesOfItem(atPath:directory.url.appendingPathComponent("vault-index.sqlite").path+$0)[.size] as? NSNumber}.reduce(Int64(0)){ $0+$1.int64Value }
        let memory=residentBytes();XCTContext.runActivity(named:"100k SQLite records: build=\(buildSeconds)s p50=\(p50)s p95=\(p95)s resident=\(memory)B db=\(dbBytes)B") { _ in }
        XCTAssertEqual(try index.allDocuments().count,100_000)
    }

    func testSearchTierSourceHasNoNetworkOrBackendDependency() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent();let source=root.appendingPathComponent("LunaLibraries/Sources/LunaVaultSearch");let text=try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil).filter{$0.pathExtension=="swift"}.map{try String(contentsOf:$0,encoding:.utf8)}.joined();XCTAssertFalse(text.contains("URLSession"));XCTAssertFalse(text.contains("LunaVaultBackend"));XCTAssertFalse(text.contains("Network.framework"))
    }
}

private func residentBytes() -> Int64 {
#if canImport(Darwin)
    var info=mach_task_basic_info();var count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
    let status=withUnsafeMutablePointer(to:&info){ pointer in pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)){ task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
    return status == KERN_SUCCESS ? Int64(info.resident_size) : 0
#else
    return 0
#endif
}

private final class RecordingSearchProtection: VaultFileProtectionApplying,@unchecked Sendable { private let lock=NSLock();private var storage:[String]=[];var paths:[String]{lock.withLock{storage}};func apply(to url:URL)throws{lock.withLock{storage.append(url.path)}};func hasRequiredProtection(at url:URL)throws->Bool{true} }
private final class LockedSearchFailures:@unchecked Sendable{private let lock=NSLock();private var storage:[Error]=[];var values:[Error]{lock.withLock{storage}};func append(_ error:Error){lock.withLock{storage.append(error)}}}
