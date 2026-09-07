//
//  TranscriptPluginHarness.swift
//  LunaTests
//

import Foundation
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import LunaPluginRuntime
import XCTest

/// Runs one BUNDLED transcript plugin (`<platform>-transcript.js`) the way the
/// app runs it, over recorded fixtures, and hands back the `article` Model it
/// produced (`claudedocs/plans/transcription-plugins.md` §7, §9).
///
/// The media twins are exercised by `MediaPluginHarness`; this harness reads
/// the OTHER half of each pair, whose Model is an article that carries either
/// caption text as `html` or a `transcription` spec for Luna to download.
final class TranscriptPluginHarness {

    let runner: PluginJSFixtureRunner
    let pluginID: String

    var fetcher: StubPluginFetcher { runner.fetcher }

    /// Loads `<name>.js` from the bundled-plugins directory beside this suite.
    init(_ name: String, id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        pluginID = id
        runner = PluginJSFixtureRunner()
        let source = try String(
            contentsOf: MediaPluginHarness.pluginsDirectory.appendingPathComponent("\(name).js"),
            encoding: .utf8)
        let reports = try runner.load(source, file: file, line: line)
        XCTAssertEqual(reports.count, 1, "\(name).js did not load", file: file, line: line)
        XCTAssertEqual(
            runner.runtime.loadedPlugins.first?.id, id,
            "\(name).js declares a different id", file: file, line: line)
    }

    func cleanUp() { runner.cleanUp() }

    // MARK: - The hooks

    /// The classify verdict, with the app's Transcribe intent when asked for.
    func classify(
        _ url: String, intent: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> PluginClassifyVerdict? {
        let outcome = await runner.runtime.invoke(
            .classify, pluginID: pluginID,
            argument: PluginClassifyInput(url: url, page: nil, context: .app, intent: intent),
            timeout: 5, decode: PluginClassifyVerdict.self)
        switch outcome {
        case .success(let verdict): return verdict
        case .failure(let failure):
            XCTFail("classify failed: \(failure)", file: file, line: line)
            return nil
        }
    }

    /// The article Model the plugin resolves for `url` through classify →
    /// ingest, or nil when it declined at either step. A Model of another kind
    /// fails the test.
    func article(
        _ url: String, page: PluginPageSnapshot? = nil, intent: String? = "transcribe",
        file: StaticString = #filePath, line: UInt = #line
    ) async -> ArticleModel? {
        let classified = await runner.runtime.invoke(
            .classify, pluginID: pluginID,
            argument: PluginClassifyInput(url: url, page: page, context: .app, intent: intent),
            timeout: 5, decode: PluginClassifyVerdict.self)
        guard case let .success(.claimed(kind, itemID, _)) = classified else { return nil }
        XCTAssertEqual(kind, .article, "the transcript plugin claimed \(kind)", file: file, line: line)
        let ingested = await runner.runtime.invoke(
            .ingest, pluginID: pluginID,
            argument: PluginIngestHookInput(
                url: url, claim: PluginIngestClaim(kind: .article, itemID: itemID),
                page: page, reason: .save, context: .app, intent: intent),
            timeout: 20, decode: PluginIngestAnswer.self)
        switch ingested {
        case .failure(let failure):
            XCTFail("ingest failed: \(failure)", file: file, line: line)
            return nil
        case .success(.declined):
            return nil
        case .success(.model(let model)):
            guard let source = URL(string: url),
                  case let .article(article) = model.resolvingRelativeURLs(against: source)
            else {
                XCTFail("the plugin returned a \(model.kind.rawValue) Model", file: file, line: line)
                return nil
            }
            return article
        }
    }
}

extension TranscriptPluginHarness {
    struct NoArticle: Error {}

    /// `article(_:)`, failing the test when the plugin declined. `XCTUnwrap`
    /// cannot wrap an `await`, so the unwrap lives here.
    func requireArticle(
        _ url: String, page: PluginPageSnapshot? = nil, intent: String? = "transcribe",
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> ArticleModel {
        guard let article = await article(url, page: page, intent: intent, file: file, line: line) else {
            XCTFail("the plugin declined \(url)", file: file, line: line)
            throw NoArticle()
        }
        return article
    }
}

/// The media twin's answer to the app's Transcribe intent: it must step aside
/// so the walk reaches the transcript plugin, and still claim a plain save.
func assertMediaTwinDeclinesTranscribeIntent(
    _ name: String, id: String, url: String,
    file: StaticString = #filePath, line: UInt = #line
) async throws {
    let twin = try MediaPluginHarness(name, id: id, file: file, line: line)
    defer { twin.cleanUp() }
    let withIntent = await twin.runner.runtime.invoke(
        .classify, pluginID: id,
        argument: PluginClassifyInput(url: url, page: nil, context: .app, intent: "transcribe"),
        timeout: 5, decode: PluginClassifyVerdict.self)
    guard case .success(let verdict) = withIntent else {
        XCTFail("\(name).js classify failed with the intent", file: file, line: line)
        return
    }
    XCTAssertEqual(verdict, .declined, "\(name).js must decline a transcribe intent", file: file, line: line)
    let plain = await twin.classify(url, file: file, line: line)
    if case .claimed(let kind, _, _) = plain {
        XCTAssertEqual(kind, .media, file: file, line: line)
    } else {
        XCTFail("\(name).js no longer claims a plain save of \(url)", file: file, line: line)
    }
}
