//
//  SafariPluginMessages+Luna.swift
//  LunaSafari
//
//  The plugin platform's native message handling
//  (`claudedocs/plans/plugin-platform.md` §13.1) — compiled ONLY into the
//  central `LunaSafari` target, the one Safari appex that actually links
//  `LunaPluginKit`/`LunaBundledPlugins`. A membership exception excludes this
//  file from the other three Safari targets' builds; their own copy of
//  `SafariPluginMessages+None.swift` answers `nil` for `SafariPluginMessages
//  .handler` instead. This is the same per-target-variant split
//  `KindWiring+Luna.swift`/`KindWiring+Reader.swift` use (see the comment
//  above `SafariPluginMessaging` in SafariWebExtensionHandler.swift for why a
//  compiler module-visibility guard is not used here instead; this file's
//  shape mirrors that split).
//
//  Every method here is an ADAPTER: parse the message, call `LunaPluginKit`,
//  serialize the answer — no plugin-runtime logic lives in this file.
//

import Foundation
import LunaBundledPlugins
import LunaModels
import LunaPluginKit
import LunaStorage
import LunaURLClassification
import SafariServices

enum SafariPluginMessages {
    static let handler: SafariPluginMessaging? = LunaSafariPluginMessageHandler()
}

/// The central host's real answer to every `plugins.*` message.
final class LunaSafariPluginMessageHandler: SafariPluginMessaging {

    /// The largest plugin source `plugins.source` will hand over. Native
    /// messaging caps a message around 1.5 MB; a plugin over the limit is
    /// skipped in Safari and logged by the content script.
    private static let pluginSourceMaxBytes = 1_500_000

    /// Long enough for a cold containing-app launch and its Live Activity to
    /// be created, but short enough that a responder-chain open which never
    /// lands cannot bounce a manual app launch back to an old Safari page
    /// tomorrow. Mirrors `SafariWebExtensionHandler.downloadReturnHandoffLifetime`
    /// (a separate constant: the two hand-offs are independent messages).
    private static let returnHandoffLifetime: TimeInterval = 60

    private let fetchService = PluginFetchService()

    /// This type is compiled only into the central appex, so being reached at
    /// all IS the "central host" signal — no bundle-id check needed here.
    var supportsPlugins: Bool { true }

    /// This extension's containing app's URL scheme, read the same way
    /// `SafariWebExtensionHandler.hostScheme` does.
    private var hostScheme: String {
        LunaDeepLink.appScheme(forBundleIdentifier: Bundle.main.bundleIdentifier)
            ?? LunaDeepLink.lunaScheme
    }

    func handle(type: String, message: [String: Any]?, context: NSExtensionContext) -> Bool {
        switch type {
        case "plugins.catalog":
            complete(context, with: pluginCatalogPayload())
        case "plugins.source":
            complete(context, with: pluginSourcePayload(message: message))
        case "plugins.fetch":
            pluginFetch(message: message, context: context)
        case "plugins.storage.get":
            complete(context, with: pluginStorageGet(message: message))
        case "plugins.storage.set":
            complete(context, with: pluginStorageSet(message: message))
        case "plugins.storage.delete":
            complete(context, with: pluginStorageDelete(message: message))
        case "plugins.storage.keys":
            complete(context, with: pluginStorageKeys(message: message))
        case "plugins.collection.put":
            complete(context, with: pluginCollectionPut(message: message))
        case "plugins.collection.get":
            complete(context, with: pluginCollectionGet(message: message))
        case "plugins.collection.delete":
            complete(context, with: pluginCollectionDelete(message: message))
        case "plugins.collection.find":
            complete(context, with: pluginCollectionFind(message: message))
        case "plugins.collection.count":
            complete(context, with: pluginCollectionCount(message: message))
        case "plugins.log":
            pluginLog(message: message)
            complete(context, with: ["ok": true])
        case "plugins.settings.get":
            complete(context, with: pluginSettingsGet(message: message))
        case "plugins.browserDeferred":
            complete(context, with: pluginBrowserDeferred(message: message))
        case "plugins.queueModel":
            complete(context, with: pluginQueueModel(message: message))
        default:
            return false
        }
        return true
    }

    private func complete(_ context: NSExtensionContext, with payload: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    // MARK: - Catalog / source

    /// This appex links `LunaBundledPlugins`, so the resource bundle its
    /// `Bundle.module` accessor names is always found here — unlike the
    /// three single-kind Safari targets, which never embed it at all.
    private var bundledPluginsResourceBundle: Bundle? {
        Bundle.main.url(forResource: "LunaLibraries_LunaBundledPlugins", withExtension: "bundle")
            .flatMap(Bundle.init(url:))
    }

    /// Bundled plugins plus imported ones, imported wins on a shared id,
    /// disabled plugins dropped. The content script never sees a plugin the
    /// user (or a repeated timeout) turned off.
    private func enabledPlugins() -> [InstalledPlugin] {
        let installed = PluginStore.shared.installedPlugins()
        let bundledCatalog = BundledPluginCatalog(
            bundle: bundledPluginsResourceBundle, subdirectory: "Plugins")
        return (bundledCatalog.plugins(shadowedBy: installed) + installed)
            .filter(\.state.isEnabled)
    }

    private func enabledPlugin(id: String) -> InstalledPlugin? {
        enabledPlugins().first { $0.id == id }
    }

    /// True only when `id` is installed, enabled, AND declares `capability` —
    /// the content script names the capability it wants, but this handler is
    /// the one that actually enforces the grant (§15).
    private func pluginDeclares(id: String, capability: PluginCapabilityName) -> Bool {
        enabledPlugin(id: id)?.manifest.capabilities.contains(capability) ?? false
    }

    /// `{stamp, plugins:[…]}` — one native round trip per page (§13.1). The
    /// stamp is a plain descriptor string, not a cryptographic hash: it only
    /// has to change when the enabled set changes, and a Swift `hashValue` is
    /// randomized per launch, so a real digest would invalidate every page's
    /// cache on every relaunch for no reason.
    private func pluginCatalogPayload() -> [String: Any] {
        let plugins = enabledPlugins().filter(\.manifest.isIngestPlugin)
        let stamp = plugins
            .map { "\($0.id)@\($0.manifest.version.description)" }
            .sorted()
            .joined(separator: "|")
        let list: [[String: Any]] = plugins.map { plugin in
            [
                "id": plugin.id,
                "hosts": plugin.manifest.hosts,
                "any": plugin.manifest.matchesAnyHost,
                "priority": plugin.manifest.priority,
                "produces": plugin.manifest.produces.map(\.rawValue),
                "capabilities": plugin.manifest.capabilities.map(\.rawValue),
            ]
        }
        return ["stamp": stamp, "plugins": list]
    }

    /// The plugin's own text, or an error the content script logs and skips.
    private func pluginSourcePayload(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String,
              let plugin = enabledPlugin(id: id), let source = plugin.sourceText()
        else { return ["error": "not-found"] }
        guard source.utf8.count <= Self.pluginSourceMaxBytes else { return ["error": "too-large"] }
        return ["source": source]
    }

    // MARK: - Fetch

    /// `luna.fetch` over `PluginFetchService` (Foundation-only, so it runs in
    /// this appex with no JavaScriptCore involved). Refused when the plugin
    /// never declared `fetch`, or asks for a file the appex has nowhere to
    /// write (`files` is never available in Safari, §6).
    private func pluginFetch(message: [String: Any]?, context: NSExtensionContext) {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .fetch),
              let requestDict = message?["request"] as? [String: Any],
              let urlString = requestDict["url"] as? String, let url = URL(string: urlString)
        else {
            complete(context, with: ["error": "capability-not-declared"])
            return
        }
        let responseForm = (requestDict["as"] as? String)
            .flatMap(PluginFetchRequest.ResponseForm.init(rawValue:)) ?? .text
        guard responseForm != .file else {
            complete(context, with: ["error": "unavailable-here"])
            return
        }
        var body: Data?
        if let bodyText = requestDict["body"] as? String {
            body = Data(bodyText.utf8)
        } else if let bodyDict = requestDict["body"] as? [String: Any],
                  let base64 = bodyDict["base64"] as? String {
            body = Data(base64Encoded: base64)
        }
        let request = PluginFetchRequest(
            url: url,
            method: (requestDict["method"] as? String) ?? "GET",
            headers: (requestDict["headers"] as? [String: String]) ?? [:],
            body: body,
            cookies: (requestDict["cookies"] as? String)
                .flatMap(PluginFetchRequest.CookiePolicy.init(rawValue:)) ?? .shared,
            redirect: (requestDict["redirect"] as? String)
                .flatMap(PluginFetchRequest.RedirectPolicy.init(rawValue:)) ?? .follow,
            maxBytes: (requestDict["maxBytes"] as? Int) ?? WebFetchConstants.maxBytes,
            timeout: (requestDict["timeout"] as? Double) ?? 20,
            responseForm: responseForm,
            invocationID: id)
        fetchService.fetch(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                var payload: [String: Any] = [
                    "ok": response.isOK, "status": response.status, "url": response.finalURL,
                    "redirected": response.redirected, "headers": response.headers,
                    "truncated": response.truncated, "bytes": response.body.count,
                ]
                switch responseForm {
                case .text: payload["text"] = String(decoding: response.body, as: UTF8.self)
                case .base64: payload["base64"] = response.body.base64EncodedString()
                case .file: break
                }
                self.complete(context, with: payload)
            case .failure(let error):
                self.complete(context, with: ["error": error.code, "message": error.message])
            }
        }
    }

    // MARK: - Storage

    private func pluginStorageGet(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String,
              pluginDeclares(id: id, capability: .storage), let key = message?["key"] as? String
        else { return ["error": "capability-not-declared"] }
        guard let json = PluginKVStore.shared.valueJSON(pluginID: id, key: key) else { return [:] }
        return ["value": Self.nativeValue(fromJSON: json) as Any]
    }

    private func pluginStorageSet(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String,
              pluginDeclares(id: id, capability: .storage), let key = message?["key"] as? String,
              let json = Self.jsonString(fromNativeValue: message?["value"])
        else { return ["error": "capability-not-declared"] }
        let ok = PluginKVStore.shared.setValueJSON(json, pluginID: id, key: key, now: Date())
        return ["ok": ok]
    }

    private func pluginStorageDelete(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String,
              pluginDeclares(id: id, capability: .storage), let key = message?["key"] as? String
        else { return ["error": "capability-not-declared"] }
        _ = PluginKVStore.shared.setValueJSON(nil, pluginID: id, key: key, now: Date())
        return ["ok": true]
    }

    private func pluginStorageKeys(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage)
        else { return ["error": "capability-not-declared"] }
        return ["keys": PluginKVStore.shared.keys(pluginID: id, prefix: message?["prefix"] as? String)]
    }

    private func pluginCollectionPut(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage),
              let collection = message?["collection"] as? String,
              let docID = message?["docId"] as? String,
              let json = Self.jsonString(fromNativeValue: message?["doc"] ?? [String: Any]())
        else { return ["error": "capability-not-declared"] }
        let document = PluginCollectionDocument(
            id: docID, json: json, k1: message?["k1"] as? String, k2: message?["k2"] as? String)
        return ["ok": PluginKVStore.shared.putDocument(document, collection: collection, pluginID: id)]
    }

    private func pluginCollectionGet(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage),
              let collection = message?["collection"] as? String,
              let docID = message?["docId"] as? String
        else { return ["error": "capability-not-declared"] }
        guard let document = PluginKVStore.shared.document(id: docID, collection: collection, pluginID: id)
        else { return [:] }
        return ["doc": Self.nativeValue(fromJSON: document.json) as Any]
    }

    private func pluginCollectionDelete(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage),
              let collection = message?["collection"] as? String,
              let docID = message?["docId"] as? String
        else { return ["error": "capability-not-declared"] }
        return [
            "ok": PluginKVStore.shared.removeDocument(id: docID, collection: collection, pluginID: id),
        ]
    }

    private func pluginCollectionFind(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage),
              let collection = message?["collection"] as? String
        else { return ["error": "capability-not-declared"] }
        let documents = PluginKVStore.shared.find(
            collection: collection, pluginID: id,
            k1: message?["k1"] as? String, k2: message?["k2"] as? String,
            limit: message?["limit"] as? Int, offset: (message?["offset"] as? Int) ?? 0)
        return ["items": documents.map { ["id": $0.id, "doc": Self.nativeValue(fromJSON: $0.json) as Any] }]
    }

    private func pluginCollectionCount(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage),
              let collection = message?["collection"] as? String
        else { return ["error": "capability-not-declared"] }
        return [
            "count": PluginKVStore.shared.count(
                collection: collection, pluginID: id,
                k1: message?["k1"] as? String, k2: message?["k2"] as? String),
        ]
    }

    // MARK: - Log / settings / browser / queueModel

    /// Always present at the bridge (§6.1) — logging needs no capability.
    private func pluginLog(message: [String: Any]?) {
        guard let id = message?["id"] as? String, let text = message?["message"] as? String
        else { return }
        DiagnosticLog.shared.record(text, category: "plugin.\(id)")
    }

    /// A field marked secret answers `""` once set and never the value it
    /// holds (§6.11) — the plugin gets to know a key exists, not what it is.
    private func pluginSettingsGet(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String,
              pluginDeclares(id: id, capability: .settings), let key = message?["key"] as? String,
              let plugin = enabledPlugin(id: id)
        else { return ["error": "capability-not-declared"] }
        let field = plugin.manifest.settings.first { $0.key == key }
        let stored = PluginKVStore.shared.settingsValueJSON(pluginID: id, key: key)
        if field?.isSecret == true {
            return stored != nil ? ["value": ""] : [:]
        }
        guard let stored else { return [:] }
        return ["value": Self.nativeValue(fromJSON: stored) as Any]
    }

    /// No save exists yet in Safari (§8.2): the plugin's `luna.browser.open`
    /// always rejects, and the deep link it hands back starts a fresh save in
    /// the app, which reaches the real browser modal with the user present.
    private func pluginBrowserDeferred(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, let urlString = message?["url"] as? String,
              pluginDeclares(id: id, capability: .browser)
        else { return ["error": "capability-not-declared"] }
        let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString
        return ["openLuna": "\(hostScheme)://save?url=\(encoded)"]
    }

    /// The page can neither write a save nor start a download: it hands the
    /// already-`ingest`ed Model over, and the app adopts it on the
    /// `pluginmodel` deep link (`KindWiring.drainPendingPluginModels`).
    private func pluginQueueModel(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String,
              let urlString = message?["url"] as? String, urlString.hasPrefix("http"),
              let modelJSON = message?["model"] as? String,
              let plugin = enabledPlugin(id: id)
        else { return ["error": "invalid-request"] }
        guard let data = modelJSON.data(using: .utf8),
              let model = try? JSONDecoder().decode(PluginModel.self, from: data),
              plugin.manifest.produces.contains(model.kind)
        else { return ["error": "malformed-model"] }
        PendingPluginModelStore.shared.put(PendingPluginModel(
            urlString: urlString, modelJSON: modelJSON, pluginID: id, createdAt: Date(),
            returnToSourceUntil: Date().addingTimeInterval(Self.returnHandoffLifetime)))
        return ["deepLink": "\(hostScheme)://pluginmodel?ret=safari"]
    }

    // MARK: - JSON <-> native value

    /// A native value (dictionary/array/string/number/bool/`NSNull`) as JSON
    /// text, for the `plugin_kv`/`plugin_collections` columns, which store
    /// JSON text rather than a typed column (§6.5). `JSONSerialization`
    /// refuses a bare scalar at the top level, so one is wrapped in an array
    /// and unwrapped again.
    private static func jsonString(fromNativeValue value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return "null" }
        if JSONSerialization.isValidJSONObject(value) {
            guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: [value], options: [.fragmentsAllowed])
        else { return nil }
        let wrapped = String(decoding: data, as: UTF8.self)
        return String(wrapped.dropFirst().dropLast())
    }

    /// The reverse of `jsonString(fromNativeValue:)`, for handing a stored
    /// value back to the page as itself rather than as JSON text.
    private static func nativeValue(fromJSON json: String) -> Any? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
