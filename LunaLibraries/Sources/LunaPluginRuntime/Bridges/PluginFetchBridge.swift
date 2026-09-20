//
//  PluginFetchBridge.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaModels
import LunaPluginKit
import LunaURLClassification

/// `luna.fetch(request)` — the one way plugin code reaches the network (§6.2).
///
/// It answers a Promise. Plugin JavaScript runs on one serial queue over a
/// shared virtual machine, so a blocking fetch would stall every other plugin
/// for the length of a network call; the promise settles back on that same
/// queue through `PluginCallbackScheduling`.
public final class PluginFetchBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.fetch

    private let fetcher: PluginURLFetching
    private let scheduler: PluginCallbackScheduling
    private let diagnostics: PluginDiagnosticsRecording
    /// Resolves a `file` part of a multipart body. Nil where no `luna.files`
    /// serves this process, and then a `file` part is refused.
    private let files: (any PluginFileReading)?

    public init(
        fetcher: PluginURLFetching,
        scheduler: PluginCallbackScheduling,
        files: (any PluginFileReading)? = nil,
        diagnostics: PluginDiagnosticsRecording = PluginDiagnostics.shared
    ) {
        self.fetcher = fetcher
        self.scheduler = scheduler
        self.files = files
        self.diagnostics = diagnostics
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let pluginID = namespace.pluginID
        let scratchGeneration = namespace.target.scratchGeneration
        let fetcher = self.fetcher
        let scheduler = self.scheduler
        let diagnostics = self.diagnostics
        let files = self.files
        let generationID = namespace.target.generationID

        let fetch: @convention(block) (JSValue?) -> JSValue? = { argument in
            let context = JSContext.current() ?? outerContext
            let invocation = scheduler.currentPluginInvocation
            var object = PluginBridgeValue.dictionary(argument)
            // `luna.fetch("https://…")` is the same call with one field.
            if object.isEmpty, argument?.isString == true, let urlString = argument?.toString() {
                object = ["url": urlString]
            }
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID,
                generationID: generationID)
            let request: PluginFetchRequest
            switch PluginFetchRequestDecoder.decode(
                object, pluginID: pluginID, generation: scratchGeneration(), files: files)
            {
            case .failure(let error):
                // A malformed request is a rejected `LunaError` like every other
                // fetch failure, so `luna.fetch(req).catch(…)` is the one place a
                // plugin handles them.
                box.fail(error.message, code: error.code)
                return promise
            case .success(let decoded):
                request = decoded
            }
            diagnostics.record(
                "fetch \(request.method) \(request.url.absoluteString) "
                    + "cookies=\(request.cookies.rawValue) redirect=\(request.redirect.rawValue)",
                pluginID: pluginID, invocation: invocation)
            fetcher.fetch(request) { outcome in
                switch outcome {
                case .success(let response):
                    diagnostics.record(
                        "fetch → \(response.status) \(response.body.count)B "
                            + "final=\(response.finalURL)"
                            + (response.truncated ? " (truncated)" : ""),
                        pluginID: pluginID, invocation: invocation)
                    box.fulfill(PluginFetchResponseEncoder.jsObject(
                        response, form: request.responseForm))
                case .failure(let error):
                    diagnostics.record(
                        "fetch → \(error.message)", pluginID: pluginID, invocation: invocation)
                    box.fail(error.message, code: error.code)
                }
            }
            return promise
        }
        // `luna.fetch` is a function that also carries `text`/`json`/`doc`.
        // The sugar is written in JavaScript rather than bridged three more
        // times, so one implementation serves all three shapes and the
        // callable stays callable. `Object.freeze` reaches it with `luna`.
        guard let factory = outerContext.evaluateScript(Self.sugarFactory),
              let wrapped = factory.call(withArguments: [fetch])
        else {
            namespace.install(fetch, as: capabilityName.rawValue)
            return
        }
        namespace.install(wrapped, as: capabilityName.rawValue)
    }

    /// The member names installed on `luna.fetch` itself.
    /// `PluginAPISurfaceTests` builds the expected `.d.ts` surface from it.
    public static let installedMembers = ["text", "json", "doc"]

    /// Wraps the native fetch so `luna.fetch(…)` still calls it and
    /// `luna.fetch.text/json/doc` read off it. `plugin_host.js` and
    /// `tools/plugin-sim/bridge.mjs` carry the same three; `PluginFetchSugarTests`
    /// and the harness's own suite pin them to each other.
    static let sugarFactory = #"""
    (function (rawFetch) {
        "use strict";

        function fetch(request) { return rawFetch(request); }

        /// One GET whose status must be a success. `opts` is the ordinary
        /// request object minus `url`; the response form is forced to text,
        /// because all three helpers read `response.text`.
        function get(url, opts) {
            var request = {};
            var source = opts || {};
            for (var key in source) {
                if (Object.prototype.hasOwnProperty.call(source, key)) {
                    request[key] = source[key];
                }
            }
            request.url = String(url);
            request.method = request.method || "GET";
            request.as = "text";
            return rawFetch(request).then(function (response) {
                if (!response || !response.ok) {
                    throw new luna.LunaError(
                        "fetch-failed",
                        request.method + " " + request.url + " answered "
                            + ((response && response.status) || 0));
                }
                return response;
            });
        }

        fetch.text = function (url, opts) {
            return get(url, opts).then(function (response) {
                return typeof response.text === "string" ? response.text : "";
            });
        };

        fetch.json = function (url, opts) {
            return get(url, opts).then(function (response) {
                try {
                    return JSON.parse(
                        typeof response.text === "string" ? response.text : "");
                } catch (error) {
                    throw new luna.LunaError(
                        "fetch-failed",
                        String(url) + " did not answer JSON: " + error.message);
                }
            });
        };

        // `luna.html` is installed after `luna.fetch` (capabilities install in
        // name order), so the namespace is read at CALL time, never captured.
        fetch.doc = function (url, opts) {
            return get(url, opts).then(function (response) {
                var html = globalThis.luna && globalThis.luna.html;
                if (!html || typeof html.parse !== "function") {
                    throw new luna.LunaError(
                        "capability-not-declared",
                        "luna.fetch.doc parses the page, so the manifest must "
                            + "declare the 'html' capability too");
                }
                var parsed = html.parse(response.text || "", response.url || String(url));
                // The stand-in for a capability this process cannot serve
                // answers a rejecting Promise from every member. Reading a
                // document off one would hand the plugin a thenable.
                if (parsed && typeof parsed.then === "function") {
                    parsed.then(function () {}, function () {});
                    throw new luna.LunaError(
                        "unavailable-here", "luna.html is not available in this process");
                }
                return parsed;
            });
        };

        return fetch;
    })
    """#
}

/// Reads the request a plugin wrote (§6.2).
///
/// The shaping itself is `PluginFetchRequestShaping` in LunaPluginKit, which
/// the Safari appex calls too; this is the JavaScriptCore entry point into it.
enum PluginFetchRequestDecoder {

    static func decode(
        _ object: [String: Any], pluginID: String, generation: String,
        files: (any PluginFileReading)?
    ) -> Result<PluginFetchRequest, PluginFetchError> {
        PluginFetchRequestShaping.request(
            from: object, pluginID: pluginID, scratchGeneration: generation, files: files)
    }
}

/// The shape a plugin sees (§6.2).
enum PluginFetchResponseEncoder {

    static func jsObject(
        _ response: PluginFetchResponse, form: PluginFetchRequest.ResponseForm
    ) -> [String: Any] {
        var object: [String: Any] = [
            "ok": response.isOK,
            "status": response.status,
            "url": response.finalURL,
            "headers": response.headers,
            "truncated": response.truncated,
            "redirected": response.redirected,
            "bytes": response.body.count,
        ]
        switch form {
        case .text:
            object["text"] = String(data: response.body, encoding: .utf8)
                ?? String(decoding: response.body, as: UTF8.self)
        case .base64:
            object["base64"] = response.body.base64EncodedString()
        case .file:
            if let file = response.file {
                object["file"] = [
                    "id": file.id, "name": file.name, "size": file.size,
                    "mime": file.mime ?? NSNull(),
                ] as [String: Any]
            }
        }
        return object
    }
}
