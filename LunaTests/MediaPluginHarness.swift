//
//  MediaPluginHarness.swift
//  LunaTests
//

import Foundation
import LunaMediaDownload
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import LunaPluginRuntime
import XCTest

/// Runs one BUNDLED media plugin the way the app runs it, over recorded
/// fixtures (`claudedocs/plans/plugin-platform.md` §13.2).
///
/// The plugin source is read from `LunaBundledPlugins/Plugins/`, so a suite
/// asserts on the file that ships rather than on a copy. The whole chain under
/// test is production code: the shipped runtime and bridges through
/// `PluginJSFixtureRunner`, then `MediaModelAdopter`, which is what turns a
/// Model into the `MediaAsset`s the download engine takes.
///
/// The plugins are ports of the Swift resolvers in LunaMediaResolve, which the
/// Downloader app still uses. Each suite therefore runs BOTH engines over the
/// same fixture and compares what they resolved: a fix to one that is not
/// mirrored in the other shows up as a disagreement rather than as a silent
/// divergence between two apps.
final class MediaPluginHarness {

    let runner: PluginJSFixtureRunner
    let pluginID: String

    var fetcher: StubPluginFetcher { runner.fetcher }

    /// Loads `<name>.js` from the bundled-plugins directory beside this suite.
    init(_ name: String, id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        pluginID = id
        runner = PluginJSFixtureRunner()
        let source = try String(
            contentsOf: Self.pluginsDirectory.appendingPathComponent("\(name).js"),
            encoding: .utf8)
        let reports = try runner.load(source, file: file, line: line)
        XCTAssertEqual(reports.count, 1, "\(name).js did not load", file: file, line: line)
        XCTAssertEqual(
            runner.runtime.loadedPlugins.first?.id, id,
            "\(name).js declares a different id", file: file, line: line)
    }

    func cleanUp() { runner.cleanUp() }

    static let pluginsDirectory = URL(fileURLWithPath: "\(#filePath)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("LunaLibraries/Sources/LunaBundledPlugins/Plugins")

    /// A recorded fixture beside this suite, as text.
    static func fixture(
        _ path: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let url = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Plugins/\(path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The hooks

    func classify(
        _ url: String, file: StaticString = #filePath, line: UInt = #line
    ) async -> PluginClassifyVerdict? {
        let outcome = await runner.runtime.invoke(
            .classify, pluginID: pluginID,
            argument: PluginClassifyInput(url: url, page: nil, context: .app),
            timeout: 5, decode: PluginClassifyVerdict.self)
        switch outcome {
        case .success(let verdict): return verdict
        case .failure(let failure):
            XCTFail("classify failed: \(failure)", file: file, line: line)
            return nil
        }
    }

    /// The assets the plugin resolves for `url`, through the same classify →
    /// ingest → adopt path the ingest stage runs. Empty means the plugin
    /// declined or found nothing, which is what keeps the Swift classifier as
    /// the floor.
    func resolve(
        _ url: String, page: PluginPageSnapshot? = nil,
        reason: PluginIngestReason = .save,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> [MediaAsset] {
        let classified = await runner.runtime.invoke(
            .classify, pluginID: pluginID,
            argument: PluginClassifyInput(url: url, page: page, context: .app),
            timeout: 5, decode: PluginClassifyVerdict.self)
        guard case let .success(.claimed(kind, itemID, _)) = classified, kind == .media else {
            return []
        }
        let ingested = await runner.runtime.invoke(
            .ingest, pluginID: pluginID,
            argument: PluginIngestHookInput(
                url: url, claim: PluginIngestClaim(kind: .media, itemID: itemID),
                page: page, reason: reason, context: .app),
            timeout: 20, decode: PluginIngestAnswer.self)
        switch ingested {
        case .failure(let failure):
            XCTFail("ingest failed: \(failure)", file: file, line: line)
            return []
        case .success(.declined):
            return []
        case .success(.model(let model)):
            guard let source = URL(string: url),
                  case let .media(media) = model.resolvingRelativeURLs(against: source)
            else {
                XCTFail("the plugin returned a \(model.kind.rawValue) Model", file: file, line: line)
                return []
            }
            guard case let .media(assets, _, _, _, _) = await MediaModelAdopter()
                .adopt(media, url: source, pluginID: pluginID)
            else { return [] }
            return assets
        }
    }

    /// The Model itself, for the fields the adopter drops.
    func model(
        _ url: String, file: StaticString = #filePath, line: UInt = #line
    ) async -> MediaModel? {
        let classified = await runner.runtime.invoke(
            .classify, pluginID: pluginID,
            argument: PluginClassifyInput(url: url, page: nil, context: .app),
            timeout: 5, decode: PluginClassifyVerdict.self)
        guard case let .success(.claimed(_, itemID, _)) = classified else { return nil }
        let ingested = await runner.runtime.invoke(
            .ingest, pluginID: pluginID,
            argument: PluginIngestHookInput(
                url: url, claim: PluginIngestClaim(kind: .media, itemID: itemID),
                page: nil, reason: .save, context: .app),
            timeout: 20, decode: PluginIngestAnswer.self)
        guard case let .success(.model(model)) = ingested,
              let source = URL(string: url),
              case let .media(media) = model.resolvingRelativeURLs(against: source)
        else { return nil }
        return media
    }
}

/// The part of a resolved asset both engines must agree on.
///
/// A plugin-resolved asset also carries the owner, the quality label and the
/// expiry — three things the Swift resolvers cannot know — so equality on
/// `MediaAsset` would compare the plugin platform against itself. This is what
/// the download actually uses.
struct ResolvedAssetShape: Equatable, CustomStringConvertible {
    let url: String
    let kind: MediaAsset.Kind
    let audioURL: String?
    let dashManifestURL: String?
    let thumbnailURL: String?
    let timeRange: MediaTimeRange?
    let estimatedByteCount: Int64?

    init(_ asset: MediaAsset) {
        url = asset.url.absoluteString
        kind = asset.kind
        audioURL = asset.audioURL?.absoluteString
        dashManifestURL = asset.dashManifestURL?.absoluteString
        thumbnailURL = asset.thumbnailURL?.absoluteString
        timeRange = asset.timeRange
        estimatedByteCount = asset.estimatedByteCount
    }

    var description: String {
        var text = "\(kind) \(url)"
        if let audioURL { text += " +audio \(audioURL)" }
        if let dashManifestURL { text += " +dash \(dashManifestURL)" }
        if let thumbnailURL { text += " poster \(thumbnailURL)" }
        if let timeRange { text += " \(timeRange.startSeconds)…\(timeRange.endSeconds ?? -1)" }
        if let estimatedByteCount { text += " \(estimatedByteCount)B" }
        return text
    }
}

extension Array where Element == MediaAsset {
    var shapes: [ResolvedAssetShape] { map(ResolvedAssetShape.init) }
}

/// Runs the Swift resolver the Downloader app still uses, answering from a
/// fixture table keyed by a substring of the request URL.
func swiftResolvedAssets(
    for urlString: String, answering answers: [(needle: String, body: String)]
) async -> [MediaAsset] {
    guard let url = URL(string: urlString) else { return [] }
    let resolver = SocialMediaResolver { request in
        let requested = request.url?.absoluteString ?? ""
        for answer in answers where requested.contains(answer.needle) {
            return Data(answer.body.utf8)
        }
        return nil
    }
    return await resolver.resolveAssets(for: url)
}
