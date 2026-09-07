//
//  PluginIngestFakes.swift
//  LunaTests
//

import Foundation
import LunaIngest
import LunaModels
import LunaPluginKit

/// A scripted `PluginHookInvoking`. Each plugin id maps to what its two hooks
/// answer, so a test states the walk it wants rather than running JavaScript.
final class FakePluginInvoker: PluginHookInvoking {

    enum Answer {
        case json(String)
        case failure(PluginInvocationFailure)
    }

    var loadedPlugins: [PluginSummary] = []
    var disabledPlugins: [String: String] = [:]

    /// `pluginID` → the classify answer.
    var classifyAnswers: [String: Answer] = [:]
    /// `pluginID` → the ingest answer.
    var ingestAnswers: [String: Answer] = [:]

    /// Every `(hook, pluginID)` asked, in order. The walk's shape is an
    /// assertion about this list.
    private(set) var calls: [(hook: PluginHook, pluginID: String)] = []
    /// The decoded `reason` of each ingest call.
    private(set) var ingestReasons: [String] = []
    /// Every hook argument as the plugin would receive it, decoded back from
    /// the JSON the runtime encodes. What a plugin sees is an assertion about
    /// these objects.
    private(set) var encodedArguments: [(hook: PluginHook, pluginID: String, json: [String: Any])] = []

    func matchedPlugins(forHost host: String) -> [PluginSummary] {
        loadedPlugins.filter { $0.matches(host: host) }
    }

    func invoke<T: Decodable>(
        _ hook: PluginHook, pluginID: String, argument: Encodable,
        timeout: TimeInterval, decode: T.Type
    ) async -> Result<T, PluginInvocationFailure> {
        calls.append((hook, pluginID))
        if let data = try? JSONEncoder().encode(argument),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            encodedArguments.append((hook, pluginID, object))
            if hook == .ingest, let reason = object["reason"] as? String {
                ingestReasons.append(reason)
            }
        }
        let answer = hook == .classify ? classifyAnswers[pluginID] : ingestAnswers[pluginID]
        switch answer {
        case .none:
            return .failure(.missingHook)
        case let .failure(failure):
            return .failure(failure)
        case let .json(text):
            guard let data = text.data(using: .utf8) else {
                return .failure(.malformedResult("not utf8"))
            }
            do {
                return .success(try JSONDecoder().decode(T.self, from: data))
            } catch {
                return .failure(.malformedResult("\(error)"))
            }
        }
    }

    func reloadAll() {}
}

extension PluginSummary {
    /// A summary that matches one host and declares both ingest hooks.
    static func fake(
        id: String, hosts: [String] = ["example.com"], priority: Int = 0,
        produces: [PluginModelKind] = [.media], matchesAnyHost: Bool = false
    ) -> PluginSummary {
        PluginSummary(
            id: id, name: id, version: "1.0.0", priority: priority,
            matchesAnyHost: matchesAnyHost, hostPatterns: hosts, produces: produces,
            hooks: [.classify, .ingest], export: nil, isBundled: false)
    }
}

/// A media adopter a test can point at without linking a real download engine.
final class FakeMediaModelAdopter: MediaModelAdopting {
    var outcome: PluginAdoptedOutcome?
    private(set) var adoptedURLs: [URL] = []

    func adopt(_ model: MediaModel, url: URL, pluginID: String) async -> PluginAdoptedOutcome {
        adoptedURLs.append(url)
        if let outcome { return outcome }
        let assets = model.assets.map {
            MediaAsset(url: $0.url, kind: .video, quality: $0.quality)
        }
        return .media(
            assets: assets, platform: .web, itemID: model.itemID,
            title: model.title, thumbnailURL: model.thumbnailURL)
    }
}

/// A scripted article adopter: answers `outcome` and remembers every Model it
/// was handed.
final class FakeArticleModelAdopter: ArticleModelAdopting {
    var outcome: PluginAdoptedOutcome = .declined
    private(set) var seen: [ArticleModel] = []

    func adopt(
        _ model: ArticleModel, url: URL, page: CapturedPage, pluginID: String
    ) async -> PluginAdoptedOutcome {
        seen.append(model)
        return outcome
    }
}

/// Swaps the three adopter slots for the duration of one test and restores them.
struct PluginAdopterScope {
    private let media: MediaModelAdopting?
    private let article: ArticleModelAdopting?
    private let product: ProductModelAdopting?

    init() {
        media = PluginModelAdopters.media
        article = PluginModelAdopters.article
        product = PluginModelAdopters.product
    }

    func restore() {
        PluginModelAdopters.media = media
        PluginModelAdopters.article = article
        PluginModelAdopters.product = product
    }
}
