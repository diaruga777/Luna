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

    static func decode(
        _ object: [String: Any], pluginID: String, generation: String,
        files: (any PluginFileReading)?
    ) -> Result<PluginFetchRequest, PluginFetchError> {
        guard let urlString = PluginBridgeValue.string(object, "url"),
              let url = URL(string: urlString), url.scheme != nil
        else {
            return .failure(PluginFetchError(
                "luna.fetch needs a url: luna.fetch({ url: \"https://…\" })",
                code: "bad-argument"))
        }
        var cookies = PluginFetchRequest.CookiePolicy.shared
        if let named = PluginBridgeValue.string(object, "cookies") {
            guard let policy = PluginFetchRequest.CookiePolicy(rawValue: named) else {
                return .failure(PluginFetchError(
                    "cookies must be \"shared\", \"ephemeral\" or \"none\"; a page's own "
                        + "session is read off the browser result's cookieHeader",
                    code: "bad-argument"))
            }
            cookies = policy
        }
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
        let body: Data?
        switch self.body(object["body"], headers: &headers, files: files) {
        case .failure(let error): return .failure(error)
        case .success(let data): body = data
        }
        let ceiling = PluginBridgeValue.int(object, "maxBytes") ?? WebFetchConstants.maxBytes
        return .success(PluginFetchRequest(
            url: url,
            method: PluginBridgeValue.string(object, "method") ?? "GET",
            headers: headers,
            body: body,
            cookies: cookies,
            redirect: PluginBridgeValue.string(object, "redirect")
                .flatMap(PluginFetchRequest.RedirectPolicy.init(rawValue:)) ?? .follow,
            maxBytes: ceiling,
            timeout: PluginBridgeValue.double(object, "timeout") ?? 20,
            responseForm: PluginBridgeValue.string(object, "as")
                .flatMap(PluginFetchRequest.ResponseForm.init(rawValue:)) ?? .text,
            invocationID: generation,
            pluginID: pluginID))
    }

    /// The five body shapes §6.2 allows. `form`, `json` and `multipart` set the
    /// content type themselves, because getting those three headers right is
    /// exactly the work a plugin should not have to repeat.
    static func body(
        _ value: Any?, headers: inout [String: String], files: (any PluginFileReading)?
    ) -> Result<Data?, PluginFetchError> {
        guard let value else { return .success(nil) }
        if let text = value as? String { return .success(Data(text.utf8)) }
        guard let object = value as? [String: Any] else { return .success(nil) }
        if let base64 = object["base64"] as? String {
            return .success(Data(base64Encoded: base64))
        }
        if let form = object["form"] as? [String: Any] {
            setIfAbsent(&headers, "Content-Type", "application/x-www-form-urlencoded")
            return .success(Data(encodeForm(form).utf8))
        }
        if let json = object["json"] {
            setIfAbsent(&headers, "Content-Type", "application/json")
            guard let data = try? JSONSerialization.data(
                withJSONObject: json, options: [.fragmentsAllowed])
            else { return .success(nil) }
            return .success(data)
        }
        if let parts = object["multipart"] as? [[String: Any]] {
            let boundary = "luna-\(UUID().uuidString)"
            setIfAbsent(&headers, "Content-Type", "multipart/form-data; boundary=\(boundary)")
            return encodeMultipart(parts, boundary: boundary, files: files)
                .map { Optional($0) }
        }
        return .success(nil)
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

    /// Builds the body, resolving every `file` part BEFORE the request leaves.
    /// A handle whose generation was reaped fails the whole fetch rather than
    /// posting a part with nothing in it.
    static func encodeMultipart(
        _ parts: [[String: Any]], boundary: String, files: (any PluginFileReading)?
    ) -> Result<Data, PluginFetchError> {
        var body = Data()
        for part in parts {
            guard let name = part["name"] as? String else { continue }
            var content: Data?
            var filename = part["filename"] as? String
            var mime = part["mime"] as? String
            if let handle = part["file"] as? [String: Any] {
                switch fileBytes(handle, files: files) {
                case .failure(let error): return .failure(error)
                case .success(let resolved):
                    content = resolved.data
                    filename = filename ?? resolved.descriptor.name
                    mime = mime ?? resolved.descriptor.mime
                }
            } else if let text = part["text"] as? String {
                content = Data(text.utf8)
            } else if let base64 = part["base64"] as? String {
                content = Data(base64Encoded: base64)
            }
            var disposition = "form-data; name=\"\(headerParameter(name))\""
            if let filename {
                disposition += "; filename=\"\(headerParameter(filename))\""
            }
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: \(disposition)\r\n".utf8))
            if let mime {
                body.append(Data("Content-Type: \(headerToken(mime))\r\n".utf8))
            }
            body.append(Data("\r\n".utf8))
            if let content { body.append(content) }
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return .success(body)
    }

    private static func fileBytes(
        _ handle: [String: Any], files: (any PluginFileReading)?
    ) -> Result<(descriptor: PluginFileDescriptor, data: Data), PluginFetchError> {
        guard let id = PluginBridgeValue.string(handle, "id") else {
            return .failure(PluginFetchError(
                "a multipart file part needs a file handle", code: "bad-argument"))
        }
        guard let files else {
            return .failure(PluginFetchError(
                "a multipart file part needs the \"files\" capability, which this process "
                    + "has not", code: "unavailable-here"))
        }
        let descriptor = PluginFileDescriptor(
            id: id,
            name: PluginBridgeValue.string(handle, "name") ?? "file",
            size: PluginBridgeValue.int(handle, "size") ?? 0,
            mime: PluginBridgeValue.string(handle, "mime"))
        guard let url = files.fileURL(for: descriptor) else {
            return .failure(PluginFetchError("that file is gone", code: "not-found"))
        }
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? Int).flatMap { $0 } ?? 0
        guard onDisk <= PluginFilesBridge.maxFileBytes else {
            return .failure(PluginFetchError(
                "a multipart file part may be at most "
                    + "\(PluginFilesBridge.maxFileBytes / (1024 * 1024)) MB",
                code: "too-large"))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(PluginFetchError("that file is gone", code: "not-found"))
        }
        return .success((descriptor, data))
    }

    /// A quoted part-header parameter that cannot forge a header or a part.
    /// Browsers percent-encode the three bytes that would; so does this.
    static func headerParameter(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    /// A bare header value — a MIME type — with the same three bytes removed.
    static func headerToken(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
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
