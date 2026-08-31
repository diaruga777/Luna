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

    // The four tests below were folded in from the deleted package-level
    // LunaVaultSearchTests target (a forbidden `.testTarget` whose 7 tests
    // never ran); these four assert behavior this file did not already cover.

    func testHybridSearchHasDeterministicTieBreakForEqualScores() throws {
        let(index,_,_)=try makeIndex();try index.upsert(doc(1,filename:"alpha.txt",body:"shared phrase",vector:[1,0]));try index.upsert(doc(2,filename:"beta.txt",body:"shared phrase",vector:[1,0]))
        let results=try index.search("shared phrase",embedding:VaultEmbedding(values:[1,0],modelVersion:"v1"),limit:10)
        XCTAssertEqual(results.map(\.filename),["alpha.txt","beta.txt"],"equal-score hits break ties by object id, not insertion order")
    }

    func testCosineSearchIsIsolatedPerModelVersion() throws {
        let(index,_,_)=try makeIndex();try index.upsert(doc(1,vector:[1,0]))
        XCTAssertEqual(try index.cosineSearch(VaultEmbedding(values:[1,0],modelVersion:"v1")).first?.0,id(1))
        XCTAssertTrue(try index.cosineSearch(VaultEmbedding(values:[1,0],modelVersion:"other-model")).isEmpty)
    }

    func testEvolveAutomaticGroupsKeepsFrozenGroupStableAcrossReEvolve() throws {
        let(index,_,_)=try makeIndex();try index.upsert(doc(1,filename:"cats.jpg",body:"cats",vector:[1,0]));try index.upsert(doc(2,filename:"kitten.jpg",body:"cats",vector:[0.99,0.01]));try index.upsert(doc(3,filename:"ocean.jpg",body:"ocean",vector:[0,1]))
        let first=try index.evolveAutomaticGroups(modelVersion:"v1",threshold:0.8);let cats=try XCTUnwrap(first.first{$0.memberIDs.count==2})
        try index.renameGroup(cats.id,label:"Pinned",frozen:true);try index.evolveAutomaticGroups(modelVersion:"v1",threshold:0.8)
        let pinned=try XCTUnwrap(try index.groups().first{$0.id==cats.id});XCTAssertEqual(pinned.label,"Pinned");XCTAssertEqual(pinned.memberIDs.count,2)
    }

    func testRebuildIsIdempotentAndPreservesSearchability() throws {
        let(index,_,_)=try makeIndex();try index.upsert(doc(1,body:"idempotent word"))
        try index.rebuild(modelVersion:"v1");try index.rebuild(modelVersion:"v1")
        XCTAssertEqual(try index.search("idempotent").count,1)
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
        let directory=try VaultTemporaryDirectory(name:"search-export-busy");addTeardownBlock{ _ = directory }
        let protection=RecordingSearchProtection()
        let index=try VaultSearchIndex(databaseURL:directory.url.appendingPathComponent("vault-index.sqlite"),
            protectionApplier:protection,walCheckpointing:BusyVaultWALCheckpointing())
        let root=try VaultRootKey(version:1,key:Data(repeating:7,count:32)),cryptor=VaultChunkedCryptor(vaultID:"search-tests",random:VaultTestRandomBytes(seed:99))
        XCTAssertThrowsError(try index.encryptedExport(cryptor:cryptor,root:root,objectID:id(500),revision:revision(500))) { error in
            guard case let VaultSearchError.sqlite(message)=error else { return XCTFail("unexpected error: \(error)") }
            XCTAssertTrue(message.contains("WAL checkpoint failed"))
        }
    }

    func testStreamingBatchesCommitBoundedPrefixAndResumeIdempotently() throws {
        let (index, _, _) = try makeIndex("search-streaming-resume")
        var next = 1
        var progress: [VaultIndexBatchProgress] = []
        XCTAssertThrowsError(try index.upsertStreaming(batchSize: 10, nextBatch: {
            guard next <= 100 else { return nil }
            let start = next
            next += 10
            if start > 20 { throw StreamFailure.injected }
            return (start..<min(start + 10, 101)).map { self.doc($0, filename: "streamrecord\($0)", body: "resumeidentifier\($0)") }
        }, progress: { progress.append($0) }))
        XCTAssertEqual(progress.last?.documentsProcessed, 20)
        XCTAssertEqual(try index.documentCount(), 20)

        var resume = 1
        let result = try index.upsertStreaming(batchSize: 10, nextBatch: {
            guard resume <= 100 else { return nil }
            let start = resume
            resume += 10
            return (start..<min(start + 10, 101)).map { self.doc($0, filename: "streamrecord\($0)", body: "resumeidentifier\($0)") }
        })
        XCTAssertEqual(result.documentsProcessed, 100)
        XCTAssertEqual(result.documentsApplied, 80)
        XCTAssertEqual(result.documentsSkipped, 20)
        XCTAssertEqual(try index.documentCount(), 100)
        XCTAssertEqual(try index.search("resumeidentifier77").count, 1)
    }

    func testStreamingBatchIsAtomicAcrossDocuments() throws {
        let (index, _, _) = try makeIndex("search-streaming-atomic")
        try index.upsert(doc(1, filename: "before", body: "before", vector: [1, 0]))
        var emitted = false
        XCTAssertThrowsError(try index.upsertStreaming(batchSize: 3, nextBatch: {
            if emitted { return nil }
            emitted = true
            return [
                self.doc(2, filename: "good", body: "good"),
                self.doc(3, filename: "bad", body: "bad", vector: [1, 0, 0]),
                self.doc(4, filename: "also-good", body: "also-good")
            ]
        }))
        XCTAssertEqual(try index.documentCount(), 1)
        XCTAssertTrue(try index.search("good").isEmpty)
        XCTAssertTrue(try index.search("also-good").isEmpty)
        XCTAssertEqual(try index.search("before").count, 1)
    }

    func testHundredThousandSQLiteRecordsPerformanceNightly() throws {
        guard ProcessInfo.processInfo.environment["LUNA_VAULT_PERFORMANCE"] == "1" else { throw XCTSkip("set LUNA_VAULT_PERFORMANCE=1 for the 100k SQLite benchmark") }
        let(index,directory,protection)=try makeIndex("search-performance-100k");let start=ProcessInfo.processInfo.systemUptime
        // 4,096 is the measured sweet spot on the iPhone 17 Pro simulator:
        // it keeps source material bounded while avoiding hundreds of WAL
        // commits. The API still caps callers at this batch size.
        var peakResident = residentBytes()
        var lastProgress = VaultIndexBatchProgress(batchNumber: 0, documentsProcessed: 0, documentsApplied: 0, documentsSkipped: 0)
        let result = try index.upsertStreaming(performanceDocuments(count: 100_000), batchSize: 4_096, progress: { progress in
            lastProgress = progress
            peakResident = max(peakResident, residentBytes())
            if progress.batchNumber == 1 || progress.batchNumber.isMultiple(of: 4) {
                XCTContext.runActivity(named: "100k index progress: batch=\(progress.batchNumber) processed=\(progress.documentsProcessed) resident=\(residentBytes())B") { _ in }
            }
        })
        XCTAssertEqual(result.documentsApplied,100_000)
        let buildSeconds=ProcessInfo.processInfo.systemUptime-start
        XCTContext.runActivity(named: "100k index phase: build=\(buildSeconds)s batches=\(lastProgress.batchNumber) processed=\(lastProgress.documentsProcessed) resident=\(residentBytes())B") { _ in }
        var queryDurations:[Double]=[];queryDurations.reserveCapacity(6);var vectorDurations:[Double]=[];vectorDurations.reserveCapacity(3);var hybridDurations:[Double]=[];hybridDurations.reserveCapacity(3)
        let queryVector = VaultEmbedding(values: [1,2,3,4,5,6,7,8].map(Float.init), modelVersion: "v1")
        // Three samples per family provide p50/p95 diagnostics while bounding
        // the O(N) exact-vector scan against the 100k-record fixture.
        for value in [1, 50_000, 100_000] {
            let marker = String(format: "%06d", value);let queryStart=ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(try index.search("vaultrecord\(marker)").count,1);queryDurations.append(ProcessInfo.processInfo.systemUptime-queryStart)
            let ftsStart=ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(try index.search("payloadmarker\(marker)").count,1);queryDurations.append(ProcessInfo.processInfo.systemUptime-ftsStart)
            let vectorStart=ProcessInfo.processInfo.systemUptime
            XCTAssertFalse(try index.cosineSearch(queryVector,limit:10).isEmpty);vectorDurations.append(ProcessInfo.processInfo.systemUptime-vectorStart)
            let hybridStart=ProcessInfo.processInfo.systemUptime
            XCTAssertFalse(try index.search("payloadmarker\(marker)",embedding:queryVector,limit:10).isEmpty);hybridDurations.append(ProcessInfo.processInfo.systemUptime-hybridStart)
            peakResident = max(peakResident, residentBytes())
        }
        let sorted=queryDurations.sorted();let p50=sorted[sorted.count/2],p95=sorted[Int(Double(sorted.count-1)*0.95)]
        let vectorSorted=vectorDurations.sorted();let vectorP50=vectorSorted[vectorSorted.count/2],vectorP95=vectorSorted[Int(Double(vectorSorted.count-1)*0.95)]
        let hybridSorted=hybridDurations.sorted();let hybridP50=hybridSorted[hybridSorted.count/2],hybridP95=hybridSorted[Int(Double(hybridSorted.count-1)*0.95)]
        let group = try index.createGroup(label: "performance group", members: [id(1)])
        let alias = try index.addManualMembership(objectID: id(1), toGroup: group.id, modelVersion: "v1")
        XCTAssertEqual(try index.groups().first(where: { $0.id == group.id })?.memberIDs, [id(1)])
        XCTAssertTrue(try index.aliases(for: id(1)).contains(where: { $0.id == alias.id }))
        try index.checkpointWAL()
        let reopened = try VaultSearchIndex(
            databaseURL: directory.url.appendingPathComponent("vault-index.sqlite"),
            protectionApplier: protection
        )
        XCTAssertEqual(try reopened.documentCount(), 100_000)
        XCTAssertEqual(try reopened.integrityCheck(), "ok")
        XCTAssertEqual(try reopened.groups().first(where: { $0.id == group.id })?.memberIDs, [id(1)])
        XCTAssertTrue(try reopened.aliases(for: id(1)).contains(where: { $0.id == alias.id }))
        let dbBytes=["","-wal","-shm"].compactMap{try? FileManager.default.attributesOfItem(atPath:directory.url.appendingPathComponent("vault-index.sqlite").path+$0)[.size] as? NSNumber}.reduce(Int64(0)){ $0+$1.int64Value }
        let memory=residentBytes(); peakResident = max(peakResident, memory)
        let totalSeconds = ProcessInfo.processInfo.systemUptime - start
        XCTContext.runActivity(named:"100k SQLite records: build=\(buildSeconds)s p50=\(p50)s p95=\(p95)s resident=\(memory)B peakResident=\(peakResident)B db=\(dbBytes)B") { _ in }
        XCTContext.runActivity(named:"100k query metrics: lexical p50=\(p50)s p95=\(p95)s vector p50=\(vectorP50)s p95=\(vectorP95)s hybrid p50=\(hybridP50)s p95=\(hybridP95)s checkpointed db+wal+shm=\(dbBytes)B resident=\(memory)B peakResident=\(peakResident)B") { _ in }
        if peakResident > 0 { XCTAssertLessThan(peakResident,768*1024*1024,"streaming index must not retain the 100k-document input") }
        XCTAssertLessThan(totalSeconds, 15 * 60, "the simulator 100k stress gate must complete within its documented 15-minute budget")
        XCTAssertEqual(try index.documentCount(),100_000)
    }

    private func performanceDocuments(count: Int) -> AnySequence<VaultIndexedDocument> {
        AnySequence { var value=1;return AnyIterator<VaultIndexedDocument> { guard value<=count else{return nil};defer{value += 1};let marker=String(format:"%06d",value);return self.doc(value,filename:"vaultrecord\(marker).txt",body:"payloadmarker\(marker)",vector:[1,2,3,4,5,6,7,8].map(Float.init)) } }
    }

    func testSearchTierSourceHasNoNetworkOrBackendDependency() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent();let source=root.appendingPathComponent("LunaLibraries/Sources/LunaVaultSearch");let text=try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil).filter{$0.pathExtension=="swift"}.map{try String(contentsOf:$0,encoding:.utf8)}.joined();XCTAssertFalse(text.contains("URLSession"));XCTAssertFalse(text.contains("LunaVaultBackend"));XCTAssertFalse(text.contains("Network.framework"))
    }
}

private enum StreamFailure: Error { case injected }

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
private struct BusyVaultWALCheckpointing: VaultWALCheckpointing { func checkpoint(database: OpaquePointer) -> Int32 { 5 /* SQLITE_BUSY */ } }
private final class LockedSearchFailures:@unchecked Sendable{private let lock=NSLock();private var storage:[Error]=[];var values:[Error]{lock.withLock{storage}};func append(_ error:Error){lock.withLock{storage.append(error)}}}
