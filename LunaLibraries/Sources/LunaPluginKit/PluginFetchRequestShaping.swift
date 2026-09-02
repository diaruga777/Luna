//
//  PluginFetchRequestShaping.swift
//  LunaPluginKit
//

import Foundation
import LunaURLClassification

/// The largest file the plugin platform moves through JavaScript: what
/// `luna.files.write` accepts, and what a multipart `file` part may carry.
public enum PluginFileLimits {
    public static let maxBytes = 8 * 1024 * 1024
}

/// Turns the request object a plugin wrote into a `PluginFetchRequest`
/// (`claudedocs/plugins.md` §5.1).
///
/// It lives in LunaPluginKit, and reads a plain `[String: Any]`, because THREE
/// processes shape the same request: the JavaScriptCore bridge in the app and
/// the share/action extensions, and the Safari appex, which links this module
/// and no JavaScriptCore at all. A second hand-written shaping in the appex is
/// what dropped `userAgent` and every structured body there;
/// `PluginFetchShapingParityTests` pins the two call sites to this one answer.
public enum PluginFetchRequestShaping {

    /// The request, or the `LunaError` the plugin's promise rejects with.
    ///
    /// `files` resolves a multipart `file` part. Nil where no `luna.files`
    /// serves this process — Safari — and a `file` part is then refused rather
    /// than posted empty.
    public static func request(
        from object: [String: Any], pluginID: String, scratchGeneration: String,
        files: (any PluginFileReading)?
    ) -> Result<PluginFetchRequest, PluginFetchError> {
        guard let urlString = string(object, "url"),
              let url = URL(string: urlString), url.scheme != nil
        else {
            return .failure(PluginFetchError(
                "luna.fetch needs a url: luna.fetch({ url: \"https://…\" })",
                code: "bad-argument"))
        }
        var cookies = PluginFetchRequest.CookiePolicy.shared
        if let named = string(object, "cookies") {
            guard let policy = PluginFetchRequest.CookiePolicy(rawValue: named) else {
                return .failure(PluginFetchError(
                    "cookies must be \"shared\", \"ephemeral\" or \"none\"; a page's own "
                        + "session is read off the browser result's cookieHeader",
                    code: "bad-argument"))
            }
            cookies = policy
        }
        var redirect = PluginFetchRequest.RedirectPolicy.follow
        if let named = string(object, "redirect") {
            guard let policy = PluginFetchRequest.RedirectPolicy(rawValue: named) else {
                return .failure(PluginFetchError(
                    "redirect must be \"follow\", \"manual\" or \"headThenGet\"",
                    code: "bad-argument"))
            }
            redirect = policy
        }
        var responseForm = PluginFetchRequest.ResponseForm.text
        if let named = string(object, "as") {
            guard let form = PluginFetchRequest.ResponseForm(rawValue: named) else {
                return .failure(PluginFetchError(
                    "as must be \"text\", \"base64\" or \"file\"", code: "bad-argument"))
            }
            responseForm = form
        }
        var headers = stringDictionary(object, "headers")
        // `Host` and `Content-Length` are URLSession's to set; a plugin that
        // writes them would produce a request the server reads as malformed.
        for reserved in ["host", "content-length"] {
            headers = headers.filter { $0.key.lowercased() != reserved }
        }
        if let userAgent = string(object, "userAgent") {
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
        return .success(PluginFetchRequest(
            url: url,
            method: string(object, "method") ?? "GET",
            headers: headers,
            body: body,
            cookies: cookies,
            redirect: redirect,
            maxBytes: int(object, "maxBytes") ?? WebFetchConstants.maxBytes,
            timeout: double(object, "timeout") ?? 20,
            responseForm: responseForm,
            invocationID: scratchGeneration,
            pluginID: pluginID))
    }

    // MARK: - Body

    /// The five body shapes §5.1 allows. `form`, `json` and `multipart` set the
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
        guard let id = string(handle, "id") else {
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
            name: string(handle, "name") ?? "file",
            size: int(handle, "size") ?? 0,
            mime: string(handle, "mime"))
        guard let url = files.fileURL(for: descriptor) else {
            return .failure(PluginFetchError("that file is gone", code: "not-found"))
        }
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? Int).flatMap { $0 } ?? 0
        guard onDisk <= PluginFileLimits.maxBytes else {
            return .failure(PluginFetchError(
                "a multipart file part may be at most "
                    + "\(PluginFileLimits.maxBytes / (1024 * 1024)) MB",
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

    // MARK: - Reading the object

    // A JavaScriptCore dictionary and a Safari native message deliver the same
    // shapes — `String` and `NSNumber` — so one set of readers serves both.
    // An empty string reads as absent: a plugin writing `userAgent: ""` means
    // "no opinion", not "send an empty header".

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let text = object[key] as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func int(_ object: [String: Any], _ key: String) -> Int? {
        (object[key] as? NSNumber)?.intValue
    }

    private static func double(_ object: [String: Any], _ key: String) -> Double? {
        (object[key] as? NSNumber)?.doubleValue
    }

    private static func stringDictionary(
        _ object: [String: Any], _ key: String
    ) -> [String: String] {
        guard let raw = object[key] as? [String: Any] else { return [:] }
        return raw.compactMapValues { $0 as? String }
    }
}
