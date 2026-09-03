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
import LunaAppConfig
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

    /// The enabled set, read once and kept for the life of the appex process.
    /// Every `plugins.*` message otherwise rescans the store's directory and
    /// re-parses every manifest, and one classify makes twenty of them inside
    /// an ~80 MB appex whose message chain blocks the page.
    /// `plugins.catalog` — the page's FIRST message, and the one that builds
    /// the stamp the content script caches by — rebuilds it, so a plugin the
    /// user enabled or removed in the app is picked up on the next page.
    private var cachedEnabledPlugins: [InstalledPlugin]?
    private let cacheLock = NSLock()

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
        case "plugins.recoveryHandoff":
            complete(context, with: pluginRecoveryHandoff(message: message))
        default:
            return false
        }
        return true
    }

    /// The plugin is installed and enabled but never declared the capability
    /// this message needs. Reserved for exactly that: a malformed message
    /// answers `bad-argument` instead, so an author debugging a typo is not
    /// told their manifest is wrong.
    private static let notDeclared: [String: Any] = ["error": "capability-not-declared"]

    private static func badArgument(_ detail: String) -> [String: Any] {
        ["error": "bad-argument", "message": detail]
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
    private func enabledPlugins(rescanning: Bool = false) -> [InstalledPlugin] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if !rescanning, let cachedEnabledPlugins { return cachedEnabledPlugins }
        let installed = PluginStore.shared.installedPlugins()
        let bundledCatalog = BundledPluginCatalog(
            bundle: bundledPluginsResourceBundle, subdirectory: "Plugins")
        let enabled = (bundledCatalog.plugins(shadowedBy: installed) + installed)
            .filter(\.state.isEnabled)
        cachedEnabledPlugins = enabled
        return enabled
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
        let plugins = enabledPlugins(rescanning: true).filter(\.manifest.isIngestPlugin)
        let stamp = plugins
            .map { "\($0.id)@\($0.manifest.version.description)" }
            .sorted()
            .joined(separator: "|")
        let list: [[String: Any]] = plugins.map { plugin in
            [
                "id": plugin.id,
                "version": plugin.manifest.version.description,
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
    /// this appex with no JavaScriptCore involved). The request is shaped by
    /// `PluginFetchRequestShaping`, the same type the JavaScriptCore bridge
    /// calls, so a `userAgent` identity and a `form`/`json`/`multipart` body
    /// mean here exactly what they mean in the app. Refused when the plugin
    /// never declared `fetch`, or asks for a file the appex has nowhere to
    /// write (`files` is never available in Safari, §5).
    private func pluginFetch(message: [String: Any]?, context: NSExtensionContext) {
        guard let id = message?["id"] as? String else {
            complete(context, with: ["error": "bad-argument", "message": "no plugin id"])
            return
        }
        guard pluginDeclares(id: id, capability: .fetch) else {
            complete(context, with: Self.notDeclared)
            return
        }
        let request: PluginFetchRequest
        switch PluginFetchRequestShaping.request(
            from: (message?["request"] as? [String: Any]) ?? [:],
            pluginID: id, scratchGeneration: id, files: nil)
        {
        case .failure(let error):
            complete(context, with: ["error": error.code, "message": error.message])
            return
        case .success(let shaped):
            request = shaped
        }
        let responseForm = request.responseForm
        guard responseForm != .file else {
            complete(context, with: [
                "error": "unavailable-here",
                "message": "as: \"file\" needs the \"files\" capability, which Safari has not",
            ])
            return
        }
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

    /// An absent `value` field IS a missing key: the content script reads
    /// `r.value` off the reply and answers `undefined`, the same answer
    /// `PluginStorageBridge.get` gives.
    private func pluginStorageGet(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage)
        else { return Self.notDeclared }
        guard let key = message?["key"] as? String, !key.isEmpty
        else { return Self.badArgument("luna.storage.get needs a key") }
        guard let json = PluginKVStore.shared.valueJSON(pluginID: id, key: key) else { return [:] }
        return ["value": Self.nativeValue(fromJSON: json) as Any]
    }

    /// `undefined` is not a value, and a native message drops an undefined
    /// field — so an absent `value` IS `luna.storage.set(key, undefined)`,
    /// which `PluginStorageBridge.set` rejects `bad-argument` too. A row over
    /// the cap answers `too-large` rather than `ok: false`, which the content
    /// script used to read as a successful write.
    private func pluginStorageSet(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage)
        else { return Self.notDeclared }
        guard let key = message?["key"] as? String, !key.isEmpty
        else { return Self.badArgument("luna.storage.set needs a key") }
        guard let value = message?["value"] else {
            return Self.badArgument(
                "luna.storage.set needs a value; use delete to remove a key")
        }
        guard let json = Self.jsonString(fromNativeValue: value) else {
            return Self.badArgument("luna.storage.set needs a JSON value")
        }
        guard PluginKVStore.shared.setValueJSON(json, pluginID: id, key: key, now: Date()) else {
            return [
                "error": "too-large",
                "message": "the value is larger than the "
                    + "\(PluginKVStore.maxValueBytes / 1024) KB one key may hold",
            ]
        }
        return ["ok": true]
    }

    private func pluginStorageDelete(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage)
        else { return Self.notDeclared }
        guard let key = message?["key"] as? String, !key.isEmpty
        else { return Self.badArgument("luna.storage.delete needs a key") }
        _ = PluginKVStore.shared.setValueJSON(nil, pluginID: id, key: key, now: Date())
        return ["ok": true]
    }

    private func pluginStorageKeys(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage)
        else { return Self.notDeclared }
        return ["keys": PluginKVStore.shared.keys(pluginID: id, prefix: message?["prefix"] as? String)]
    }

    private func pluginCollectionPut(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage)
        else { return Self.notDeclared }
        guard let collection = message?["collection"] as? String, !collection.isEmpty,
              let docID = message?["docId"] as? String, !docID.isEmpty
        else { return Self.badArgument("a collection put needs a collection and a document id") }
        guard let json = Self.jsonString(fromNativeValue: message?["doc"] ?? [String: Any]())
        else { return Self.badArgument("a collection document must be JSON") }
        let document = PluginCollectionDocument(
            id: docID, json: json, k1: message?["k1"] as? String, k2: message?["k2"] as? String)
        guard PluginKVStore.shared.putDocument(document, collection: collection, pluginID: id)
        else {
            return [
                "error": "too-large",
                "message": "the document is larger than one row may hold",
            ]
        }
        return ["ok": true]
    }

    private func pluginCollectionGet(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage)
        else { return Self.notDeclared }
        guard let collection = message?["collection"] as? String, !collection.isEmpty,
              let docID = message?["docId"] as? String, !docID.isEmpty
        else { return Self.badArgument("a collection get needs a collection and a document id") }
        guard let document = PluginKVStore.shared.document(id: docID, collection: collection, pluginID: id)
        else { return [:] }
        return ["doc": Self.nativeValue(fromJSON: document.json) as Any]
    }

    /// Removing a document that was never there is not a failure — the
    /// JavaScriptCore bridge resolves either way — so the reply is always
    /// `ok`, and `ok: false` stays a signal the content script may reject on.
    private func pluginCollectionDelete(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage)
        else { return Self.notDeclared }
        guard let collection = message?["collection"] as? String, !collection.isEmpty,
              let docID = message?["docId"] as? String, !docID.isEmpty
        else { return Self.badArgument("a collection delete needs a collection and a document id") }
        _ = PluginKVStore.shared.removeDocument(id: docID, collection: collection, pluginID: id)
        return ["ok": true]
    }

    private func pluginCollectionFind(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage)
        else { return Self.notDeclared }
        guard let collection = message?["collection"] as? String, !collection.isEmpty
        else { return Self.badArgument("a collection find needs a collection") }
        let documents = PluginKVStore.shared.find(
            collection: collection, pluginID: id,
            k1: message?["k1"] as? String, k2: message?["k2"] as? String,
            limit: message?["limit"] as? Int, offset: (message?["offset"] as? Int) ?? 0)
        return ["items": documents.map { ["id": $0.id, "doc": Self.nativeValue(fromJSON: $0.json) as Any] }]
    }

    private func pluginCollectionCount(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .storage)
        else { return Self.notDeclared }
        guard let collection = message?["collection"] as? String, !collection.isEmpty
        else { return Self.badArgument("a collection count needs a collection") }
        return [
            "count": PluginKVStore.shared.count(
                collection: collection, pluginID: id,
                k1: message?["k1"] as? String, k2: message?["k2"] as? String),
        ]
    }

    // MARK: - Log / settings / browser / queueModel

    /// Always present at the bridge (§5) — logging needs no capability. It
    /// still needs a PLUGIN: the id names a category in the shared diagnostic
    /// log, so an id no enabled plugin owns writes nothing.
    private func pluginLog(message: [String: Any]?) {
        guard let id = message?["id"] as? String, enabledPlugin(id: id) != nil,
              let text = message?["message"] as? String
        else { return }
        DiagnosticLog.shared.record(text, category: "plugin.\(id)")
    }

    /// The stored value, or the manifest field's own default — the answer
    /// `PluginSettingsBridge.value` gives in the app, so a plugin reading a
    /// setting nobody has touched works the same on both surfaces. A field
    /// marked secret answers `""` once set and never the value it holds
    /// (§5.4): the plugin gets to know a key exists, not what it is.
    private func pluginSettingsGet(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String,
              pluginDeclares(id: id, capability: .settings), let plugin = enabledPlugin(id: id)
        else { return Self.notDeclared }
        guard let key = message?["key"] as? String, !key.isEmpty
        else { return Self.badArgument("luna.settings.get needs a key") }
        let stored = PluginKVStore.shared.valueJSON(pluginID: id, key: key)
        // A key starting with `_` is Luna's own, is never declared, and has no
        // default — it answers whatever is stored.
        guard !key.hasPrefix("_") else {
            guard let stored else { return [:] }
            return ["value": Self.nativeValue(fromJSON: stored) as Any]
        }
        guard let field = plugin.manifest.settings.first(where: { $0.key == key })
        else { return [:] }
        if field.isSecret {
            return stored != nil ? ["value": ""] : [:]
        }
        guard let json = stored ?? field.defaultJSON else { return [:] }
        return ["value": Self.nativeValue(fromJSON: json) as Any]
    }

    /// No save exists yet in Safari (§8.2): the plugin's `luna.browser.open`
    /// always rejects, and the deep link it hands back starts a fresh save in
    /// the app, which reaches the real browser modal with the user present.
    private func pluginBrowserDeferred(message: [String: Any]?) -> [String: Any] {
        guard let id = message?["id"] as? String, pluginDeclares(id: id, capability: .browser)
        else { return Self.notDeclared }
        guard let urlString = message?["url"] as? String, !urlString.isEmpty
        else { return Self.badArgument("luna.browser.open needs a url") }
        guard let link = LunaDeepLink.saveLink(scheme: hostScheme, urlString: urlString) else {
            return Self.badArgument("luna.browser.open could not build the app handoff")
        }
        return ["openLuna": link.absoluteString]
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

    /// Stores the bounded evidence from a page whose plugin walk exhausted all
    /// matching plugins. The content script still owns the walk; this adapter
    /// only turns its ordered outcome records into the shared recovery-case
    /// contract and returns a short central-Luna route. No URL/evidence is put
    /// in the deep-link query, where nested `?`, `&`, `+`, fragments, and
    /// Unicode would be fragile.
    private func pluginRecoveryHandoff(message: [String: Any]?) -> [String: Any] {
        guard let urlString = message?["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return Self.badArgument("recovery handoff needs an http(s) url") }

        let page = message?["page"] as? [String: Any]
        let digest = (page?["digest"] as? String) ?? (page?["html"] as? String)
        let wasTruncated = page?["truncated"] as? Bool ?? false
        let rawOutcomes = message?["outcomes"] as? [[String: Any]] ?? []
        let attempts = rawOutcomes.prefix(PluginRecoveryCase.maxAttempts).map { outcome in
            PluginRecoveryAttempt(
                phase: outcome["phase"] as? String ?? "classify",
                strategy: outcome["pluginID"] as? String,
                result: outcome["result"] as? String ?? "observed",
                message: outcome["message"] as? String)
        }
        let matches = recoveryPlugins(from: message?["plugins"] as? [[String: Any]], outcomes: rawOutcomes)
        var redactions = ["Safari page evidence is untrusted data"]
        if wasTruncated { redactions.append("Safari page snapshot truncated") }
        if digest == nil { redactions.append("page evidence unavailable") }
        let recoveryCase = PluginRecoveryCase(
            originalURL: urlString, canonicalURL: urlString, source: .manual,
            appVersion: AppConfig.appVersion, locale: Locale.current.identifier,
            languages: Locale.preferredLanguages, outcome: "failed",
            failureReason: "Safari plugin walk exhausted",
            attempts: attempts, attemptsDropped: max(0, rawOutcomes.count - attempts.count),
            matchingPlugins: matches,
            matchingPluginsDropped: max(0, (message?["plugins"] as? [[String: Any]] ?? []).count - matches.count),
            pageDigest: digest, redactions: redactions, evidenceTruncated: wasTruncated)

        guard PluginRecoveryHandoffStore.shared.record(recoveryCase, validationURL: url),
              let link = LunaDeepLink.pluginRecoveryLink(caseID: recoveryCase.caseID)
        else { return ["ok": false, "error": "storage-unavailable"] }
        return ["ok": true, "deepLink": link.absoluteString, "case": recoveryCase.caseID.uuidString]
    }

    private func recoveryPlugins(
        from rawPlugins: [[String: Any]]?, outcomes: [[String: Any]]
    ) -> [PluginRecoveryPlugin] {
        var values: [PluginRecoveryPlugin] = []
        var seen = Set<String>()
        for raw in rawPlugins ?? [] {
            guard let id = raw["id"] as? String, seen.insert(id).inserted else { continue }
            values.append(PluginRecoveryPlugin(
                id: id, version: raw["version"] as? String,
                status: raw["status"] as? String ?? "enabled",
                hooks: raw["hooks"] as? [String] ?? [], outcome: nil))
        }
        // Older content scripts did not send a separate plugin inventory. Keep
        // their outcomes useful by deriving the same ordered inventory here.
        for raw in outcomes {
            guard let id = raw["pluginID"] as? String, seen.insert(id).inserted else { continue }
            values.append(PluginRecoveryPlugin(
                id: id, version: raw["version"] as? String, status: "enabled",
                hooks: [], outcome: raw["result"] as? String))
        }
        return values
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
