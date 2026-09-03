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

        let fetch: @convention(block) (JSValue?) -> JSValue? = { argument in
            let context = JSContext.current() ?? outerContext
            let invocation = scheduler.currentPluginInvocation
            var object = PluginBridgeValue.dictionary(argument)
            // `luna.fetch("https://…")` is the same call with one field.
            if object.isEmpty, argument?.isString == true, let urlString = argument?.toString() {
                object = ["url": urlString]
            }
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID)
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
        namespace.install(fetch, as: capabilityName.rawValue)
    }
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
