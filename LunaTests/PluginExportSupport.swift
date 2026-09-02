//
//  PluginExportSupport.swift
//  LunaTests
//

import Foundation
import LunaModels
import LunaPluginExport
import LunaPluginKit
import UIKit
import XCTest

/// A `PluginHookInvoking` that answers from a canned JSON string and records
/// the argument it was handed, so a test asserts on the input the export tier
/// BUILT as well as on what it did with the answer.
final class ExportFakeInvoker: PluginHookInvoking {

    var plugins: [PluginSummary] = []
    /// The JSON the hook "returned". Ignored when `failure` is set.
    var resultJSON = "null"
    var failure: PluginInvocationFailure?
    private(set) var argumentJSON: [String] = []
    private(set) var calls: [(hook: PluginHook, pluginID: String)] = []

    var loadedPlugins: [PluginSummary] { plugins }
    var disabledPlugins: [String: String] { [:] }

    func matchedPlugins(forHost host: String) -> [PluginSummary] { plugins }

    func invoke<T: Decodable>(
        _ hook: PluginHook, pluginID: String, argument: Encodable, timeout: TimeInterval,
        decode: T.Type
    ) async -> Result<T, PluginInvocationFailure> {
        calls.append((hook, pluginID))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(EncodableBox(argument)) {
            argumentJSON.append(String(decoding: data, as: UTF8.self))
        }
        if let failure { return .failure(failure) }
        do {
            let boxed = Data("{\"value\":\(resultJSON)}".utf8)
            return .success(try JSONDecoder().decode(ResultBox<T>.self, from: boxed).value)
        } catch {
            return .failure(.malformedResult("\(error)"))
        }
    }

    func reloadAll() {}

    private struct EncodableBox: Encodable {
        let wrapped: Encodable
        init(_ wrapped: Encodable) { self.wrapped = wrapped }
        func encode(to encoder: Encoder) throws { try wrapped.encode(to: encoder) }
    }

    private struct ResultBox<T: Decodable>: Decodable { let value: T }
}

extension FakePluginSettingsStore {
    /// Writes a string value the way `luna.settings.set` would.
    func setString(_ value: String, pluginID: String, key: String) {
        try? setValueJSON("\"\(value)\"", pluginID: pluginID, key: key)
    }
}

/// A catalog holding hand-built listings.
final class ExportFakeCatalog: PluginCatalogProviding {

    var listingsByID: [String: PluginListing] = [:]

    func listings() -> [PluginListing] { Array(listingsByID.values) }
    func listing(pluginID: String) -> PluginListing? { listingsByID[pluginID] }
    func sourceText(pluginID: String) -> String? { nil }
    func setEnabled(_ enabled: Bool, pluginID: String) throws {}
    func delete(pluginID: String) throws {}
}

/// Records what the export stage handed to the share sheet.
@MainActor
final class RecordingExportSharePresenter: PluginExportSharePresenting {
    private(set) var shares: [[Any]] = []
    private var completions: [() -> Void] = []

    func presentExportShare(
        items: [Any], from presenter: UIViewController?, sourceView: UIView?,
        completion: @escaping () -> Void
    ) {
        shares.append(items)
        completions.append(completion)
    }

    /// Runs every share's completion, as dismissing the sheet does.
    func finishShares() {
        let pending = completions
        completions = []
        for completion in pending { completion() }
    }

    var sharedURLs: [URL] { shares.flatMap { $0.compactMap { $0 as? URL } } }
}

/// The pieces a test needs to stand up the export platform without a runtime.
enum PluginExportFixtures {

    static func summary(
        id: String, name: String = "Fixture", export: PluginExportSummary?
    ) -> PluginSummary {
        PluginSummary(
            id: id, name: name, version: "1.0.0", priority: 100, matchesAnyHost: false,
            hostPatterns: [], produces: [], hooks: [.export], export: export,
            isBundled: true)
    }

    static func export(
        kinds: [PluginModelKind] = [.article], input: String = "epub",
        epubProfile: String? = nil, epubImages: Bool = true, title: String = "Send Somewhere",
        symbol: String? = nil, isDestination: Bool = false, requiresSettings: [String] = []
    ) -> PluginExportSummary {
        PluginExportSummary(
            kinds: kinds, input: input, epubProfile: epubProfile, epubImages: epubImages,
            title: title, symbol: symbol, isDestination: isDestination,
            requiresSettings: requiresSettings)
    }

    static func listing(
        _ summary: PluginSummary, capabilities: [PluginCapabilityName] = [],
        status: PluginStatus = .enabled, settings: [PluginSettingField] = []
    ) -> PluginListing {
        PluginListing(
            summary: summary, description: nil, status: status, capabilities: capabilities,
            runsInBackground: false, settings: settings)
    }
}
