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

    public init(
        fetcher: PluginURLFetching,
        scheduler: PluginCallbackScheduling,
        diagnostics: PluginDiagnosticsRecording = PluginDiagnostics.shared
    ) {
        self.fetcher = fetcher
        self.scheduler = scheduler
        self.diagnostics = diagnostics
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let pluginID = namespace.pluginID
        let invocationID = namespace.target.invocationID
        let fetcher = self.fetcher
        let scheduler = self.scheduler
        let diagnostics = self.diagnostics

        let fetch: @convention(block) (JSValue?) -> JSValue? = { argument in
            let context = JSContext.current() ?? outerContext
            var object = PluginBridgeValue.dictionary(argument)
            // `luna.fetch("https://…")` is the same call with one field.
            if object.isEmpty, argument?.isString == true, let urlString = argument?.toString() {
                object = ["url": urlString]
            }
            guard let request = PluginFetchRequestDecoder.decode(
                object, invocationID: invocationID())
            else {
                PluginBridgeValue.raise(
                    "luna.fetch needs a url: luna.fetch({ url: \"https://…\" })", in: context)
                return nil
            }
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            diagnostics.record(
                "fetch \(request.method) \(request.url.absoluteString) "
                    + "cookies=\(request.cookies.rawValue) redirect=\(request.redirect.rawValue)",
                pluginID: pluginID)
            fetcher.fetch(request) { outcome in
                switch outcome {
                case .success(let response):
                    diagnostics.record(
                        "fetch → \(response.status) \(response.body.count)B "
                            + "final=\(response.finalURL)"
                            + (response.truncated ? " (truncated)" : ""),
                        pluginID: pluginID)
                    box.fulfill(PluginFetchResponseEncoder.jsObject(
                        response, form: request.responseForm))
                case .failure(let error):
                    diagnostics.record("fetch → \(error.message)", pluginID: pluginID)
                    box.fail(error.message, code: error.code)
                }
            }
            return promise
        }
        namespace.install(fetch, as: capabilityName.rawValue)
    }
}

/// Reads the request a plugin wrote (§6.2).
enum PluginFetchRequestDecoder {

    static func decode(_ object: [String: Any], invocationID: String) -> PluginFetchRequest? {
        guard let urlString = PluginBridgeValue.string(object, "url"),
              let url = URL(string: urlString), url.scheme != nil
        else { return nil }
        var headers = PluginBridgeValue.stringDictionary(object, "headers")
        // `Host` and `Content-Length` are URLSession's to set; a plugin that
        // writes them would produce a request the server reads as malformed.
        for reserved in ["host", "content-length"] {
            headers = headers.filter { $0.key.lowercased() != reserved }
        }
        if let userAgent = PluginBridgeValue.string(object, "userAgent") {
            if let identity = PluginCrawlerIdentity.named(userAgent) {
                headers["User-Agent"] = identity.userAgent
                if let forwarded = identity.xForwardedFor {
                    headers["X-Forwarded-For"] = forwarded
                }
            } else {
                headers["User-Agent"] = userAgent
            }
        }
        let body = self.body(object["body"], headers: &headers)
        let ceiling = PluginBridgeValue.int(object, "maxBytes") ?? WebFetchConstants.maxBytes
        return PluginFetchRequest(
            url: url,
            method: PluginBridgeValue.string(object, "method") ?? "GET",
            headers: headers,
            body: body,
            cookies: PluginBridgeValue.string(object, "cookies")
                .flatMap(PluginFetchRequest.CookiePolicy.init(rawValue:)) ?? .shared,
            redirect: PluginBridgeValue.string(object, "redirect")
                .flatMap(PluginFetchRequest.RedirectPolicy.init(rawValue:)) ?? .follow,
            maxBytes: ceiling,
            timeout: PluginBridgeValue.double(object, "timeout") ?? 20,
            responseForm: PluginBridgeValue.string(object, "as")
                .flatMap(PluginFetchRequest.ResponseForm.init(rawValue:)) ?? .text,
            invocationID: invocationID)
    }

    /// The five body shapes §6.2 allows. `form`, `json` and `multipart` set the
    /// content type themselves, because getting those three headers right is
    /// exactly the work a plugin should not have to repeat.
    static func body(_ value: Any?, headers: inout [String: String]) -> Data? {
        guard let value else { return nil }
        if let text = value as? String { return Data(text.utf8) }
        guard let object = value as? [String: Any] else { return nil }
        if let base64 = object["base64"] as? String {
            return Data(base64Encoded: base64)
        }
        if let form = object["form"] as? [String: Any] {
            setIfAbsent(&headers, "Content-Type", "application/x-www-form-urlencoded")
            return Data(encodeForm(form).utf8)
        }
        if let json = object["json"] {
            setIfAbsent(&headers, "Content-Type", "application/json")
            guard let data = try? JSONSerialization.data(
                withJSONObject: json, options: [.fragmentsAllowed])
            else { return nil }
            return data
        }
        if let parts = object["multipart"] as? [[String: Any]] {
            let boundary = "luna-\(UUID().uuidString)"
            setIfAbsent(&headers, "Content-Type", "multipart/form-data; boundary=\(boundary)")
            return encodeMultipart(parts, boundary: boundary)
        }
        return nil
    }

    private static func setIfAbsent(
        _ headers: inout [String: String], _ name: String, _ value: String
    ) {
        guard !headers.keys.contains(where: { $0.lowercased() == name.lowercased() }) else {
            return
        }
        headers[name] = value
    }

    static func encodeForm(_ form: [String: Any]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.keys.sorted().compactMap { key -> String? in
            guard let raw = form[key] else { return nil }
            let value = (raw as? String) ?? String(describing: raw)
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(name)=\(encoded)"
        }.joined(separator: "&")
    }

    static func encodeMultipart(_ parts: [[String: Any]], boundary: String) -> Data {
        var body = Data()
        for part in parts {
            guard let name = part["name"] as? String else { continue }
            var disposition = "form-data; name=\"\(name)\""
            if let filename = part["filename"] as? String {
                disposition += "; filename=\"\(filename)\""
            }
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: \(disposition)\r\n".utf8))
            if let mime = part["mime"] as? String {
                body.append(Data("Content-Type: \(mime)\r\n".utf8))
            }
            body.append(Data("\r\n".utf8))
            if let text = part["text"] as? String {
                body.append(Data(text.utf8))
            } else if let base64 = part["base64"] as? String,
                      let data = Data(base64Encoded: base64) {
                body.append(data)
            }
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
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
