import Foundation
import LunaVaultCrypto
import LunaVaultEmbeddings
import LunaVaultModels
import LunaVaultSearch
import LunaVaultStorage
import VaultTestKit
import XCTest

final class VaultSearchTests: XCTestCase {
    private func makeIndex(_ name: String = "search") throws -> (VaultSearchIndex, VaultTemporaryDirectory, RecordingSearchProtection) {
        let directory = try VaultTemporaryDirectory(name: name)
        let protection = RecordingSearchProtection()
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

    func testSnapshotsRejectDuplicatesAndTombstonesWhileLiveGroupsRefresh() throws {
        let(index,_,_)=try makeIndex();try index.upsert(doc(1,body:"mars"));XCTAssertThrowsError(try index.createQueryGroup(query:"mars",members:[id(1),id(1)]));let snapshot=try index.createQueryGroup(query:"mars",members:[id(1)]);let live=try index.createQueryGroup(query:"mars",members:[],live:true);try index.upsert(doc(2,body:"mars"));XCTAssertEqual(try index.queryGroup(snapshot.id)?.memberIDs,[id(1)]);XCTAssertEqual(Set(try XCTUnwrap(index.queryGroup(live.id)).memberIDs),[id(1),id(2)]);try index.delete(id(1),stamp:VaultIndexRevision(logicalTime:50,deviceID:"p"));XCTAssertEqual(try index.queryGroup(snapshot.id)?.memberIDs,[]);XCTAssertThrowsError(try index.createQueryGroup(query:"mars",members:[id(1)]))
    }

    func testPunctuationLimitsReopenAndFTSOrderAreSafe() throws {
        let(index,directory,protection)=try makeIndex();try index.upsert(doc(1,filename:"2026-report.pdf",body:"budget budget budget"));try index.upsert(doc(2,filename:"other.pdf",body:"budget"));XCTAssertNoThrow(try index.search("?! budget — 2026"));XCTAssertThrowsError(try index.search("budget",limit:0));XCTAssertEqual(try index.search("budget").first?.objectID,id(1));XCTAssertTrue(protection.paths.contains{ $0.hasSuffix("vault-index.sqlite") });let reopened=try VaultSearchIndex(databaseURL:directory.url.appendingPathComponent("vault-index.sqlite"),protectionApplier:protection);XCTAssertEqual(try reopened.search("budget").count,2);XCTAssertEqual(try reopened.integrityCheck(),"ok")
    }

    func testConcurrentConnectionsUseBusyRetry() throws {
        let directory=try VaultTemporaryDirectory(name:"search-concurrent"),protection=RecordingSearchProtection(),url=directory.url.appendingPathComponent("vault-index.sqlite");let first=try VaultSearchIndex(databaseURL:url,protectionApplier:protection),second=try VaultSearchIndex(databaseURL:url,protectionApplier:protection);let failures=LockedSearchFailures();DispatchQueue.concurrentPerform(iterations:40){value in do{_ = try (value.isMultiple(of:2) ? first:second).upsert(self.doc(value+1,body:"concurrent"))}catch{failures.append(error)}};XCTAssertTrue(failures.values.isEmpty);XCTAssertEqual(try first.search("concurrent",limit:100).count,40);XCTAssertEqual(try first.integrityCheck(),"ok")
    }

    func testEncryptedExportRestoreNeverReturnsPlaintextArtifact() throws {
        let(index,directory,protection)=try makeIndex("search-export");try index.upsert(doc(1,body:"highly confidential phrase",vector:[1,0]));let root=try VaultRootKey(version:1,key:Data(repeating:7,count:32)),cryptor=VaultChunkedCryptor(chunkSize:128,vaultID:"search-tests",random:VaultTestRandomBytes(seed:99)),object=id(500),revision=revision(500);let artifact=try index.encryptedExport(cryptor:cryptor,root:root,objectID:object,revision:revision);XCTAssertFalse(artifact.encryptedFrames.contains{String(data:$0,encoding:.utf8)?.contains("highly confidential") == true});let restored=directory.url.appendingPathComponent("restored.sqlite");try VaultSearchIndex.restoreEncryptedExport(artifact,cryptor:cryptor,to:restored,protectionApplier:protection){_ in root};let reopened=try VaultSearchIndex(databaseURL:restored,protectionApplier:protection);XCTAssertEqual(try reopened.search("confidential").count,1)
    }

    func testHundredThousandExactVectorBaselineIsMeasuredWithoutFlakyThreshold() {
        let measurement=VaultSearchPerformanceProbe.measureExactVectorBaseline(objectCount:100_000,dimension:32);XCTAssertEqual(measurement.objectCount,100_000);XCTAssertEqual(measurement.dimension,32);XCTAssertGreaterThanOrEqual(measurement.bestIndex,0);XCTAssertGreaterThan(measurement.elapsed,0);XCTContext.runActivity(named:"100k exact vector baseline: \(measurement.elapsed)s") { _ in }
    }

    func testSearchTierSourceHasNoNetworkOrBackendDependency() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent();let source=root.appendingPathComponent("LunaLibraries/Sources/LunaVaultSearch");let text=try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil).filter{$0.pathExtension=="swift"}.map{try String(contentsOf:$0,encoding:.utf8)}.joined();XCTAssertFalse(text.contains("URLSession"));XCTAssertFalse(text.contains("LunaVaultBackend"));XCTAssertFalse(text.contains("Network.framework"))
    }
}

private final class RecordingSearchProtection: VaultFileProtectionApplying,@unchecked Sendable { private let lock=NSLock();private var storage:[String]=[];var paths:[String]{lock.withLock{storage}};func apply(to url:URL)throws{lock.withLock{storage.append(url.path)}};func hasRequiredProtection(at url:URL)throws->Bool{true} }
private final class LockedSearchFailures:@unchecked Sendable{private let lock=NSLock();private var storage:[Error]=[];var values:[Error]{lock.withLock{storage}};func append(_ error:Error){lock.withLock{storage.append(error)}}}
