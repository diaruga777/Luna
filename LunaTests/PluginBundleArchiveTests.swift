import LunaModels
import LunaPluginKit
import XCTest

final class PluginBundleArchiveTests: XCTestCase {
    private func source(_ id: String) -> String {
        """
        /* luna-plugin
        {"id":"\(id)","name":"Example","version":"1.0.0","api":1,"produces":["article"],"match":{"any":true}}
        */
        luna.register({classify() { return false; }});
        """
    }
    func testMultipleSourcesRoundTripVerbatim() throws {
        let sources = [source("test.one"), source("test.two")]
        let archive = try PluginBundleArchive.data(sources: sources)
        XCTAssertEqual(archive.prefix(2), Data("PK".utf8))
        XCTAssertEqual(try PluginBundleArchive.sources(in: archive), sources)
    }
    func testDuplicateIdentityFailsBeforeImport() throws {
        var archive = ZipArchiveWriter()
        archive.addEntry(path: "a.js", data: Data(source("test.same").utf8))
        archive.addEntry(path: "b.js", data: Data(source("test.same").utf8))
        XCTAssertThrowsError(try PluginBundleArchive.sources(in: archive.archiveData()))
    }
    func testTraversalAndDuplicatePathsAreRejected() {
        for path in ["../evil.js", "/evil.js", "nested/../evil.js", "nested\\evil.js", "a.js"] {
            var archive = ZipArchiveWriter()
            archive.addEntry(path: "a.js", data: Data(source("test.first").utf8))
            archive.addEntry(path: path, data: Data(source("test.second").utf8))
            XCTAssertThrowsError(try PluginBundleArchive.sources(in: archive.archiveData()), path)
        }
    }
    func testReadmeIgnoredAndNestedPluginSupported() throws {
        var archive = ZipArchiveWriter()
        archive.addEntry(path: "README.md", data: Data("Usage".utf8))
        archive.addEntry(path: "plugins/a.js", data: Data(source("test.one").utf8), compression: .deflate)
        XCTAssertEqual(try PluginBundleArchive.sources(in: archive.archiveData()), [source("test.one")])
    }
    func testInvalidMemberRejectsWholeBundle() throws {
        var archive = ZipArchiveWriter()
        archive.addEntry(path: "good.js", data: Data(source("test.one").utf8))
        archive.addEntry(path: "bad.js", data: Data("not a plugin".utf8))
        XCTAssertThrowsError(try PluginBundleArchive.sources(in: archive.archiveData()))
    }
    func testCorruptedPayloadAndTruncatedDirectoryRejected() throws {
        var archive = ZipArchiveWriter()
        archive.addEntry(path: "a.js", data: Data(source("test.one").utf8))
        var data = archive.archiveData()
        data[40] ^= 1
        XCTAssertThrowsError(try PluginBundleArchive.sources(in: data))
        XCTAssertThrowsError(try PluginBundleArchive.sources(in: Data(data.dropLast(10))))
    }
    func testExpandedPluginSizeIsBounded() {
        var archive = ZipArchiveWriter()
        archive.addEntry(path: "large.js", data: Data(repeating: 65, count: PluginBundleArchive.maximumPluginBytes + 1), compression: .deflate)
        XCTAssertThrowsError(try PluginBundleArchive.sources(in: archive.archiveData()))
    }
    func testOptionalMediaBundleIsCompleteAndNoMediaShips() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/plugins/bundles/Luna-Media.lunabundle"))
        let sources = try PluginBundleArchive.sources(in: data)
        XCTAssertEqual(sources.count, 14)
        let mediaDirectory = root.appendingPathComponent("docs/plugins/media")
        let originals = try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "js" }.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(Set(sources), Set(originals))
        let shipped = root.appendingPathComponent("LunaLibraries/Sources/LunaBundledPlugins/Plugins")
        let names = try FileManager.default.contentsOfDirectory(atPath: shipped.path).filter { $0.hasSuffix(".js") }
        XCTAssertEqual(Set(names), Set(["web.js", "nytimes.js", "url-rewrites.js", "publisher-access.js", "kindle.js", "xteink.js"]))
    }
}
