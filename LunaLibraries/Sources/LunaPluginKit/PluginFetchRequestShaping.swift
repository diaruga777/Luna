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

private let pluginMaxRequestBodyBytes = PluginFileLimits.maxBytes
private let pluginMaxEncodedBodyBytes = ((pluginMaxRequestBodyBytes + 2) / 3) * 4

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
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil
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
        let maxBytes: Int
        if object["maxBytes"] == nil {
            maxBytes = WebFetchConstants.maxBytes
        } else {
            guard let raw = object["maxBytes"] as? NSNumber,
                  CFGetTypeID(raw) != CFBooleanGetTypeID() else {
                return .failure(PluginFetchError(
                    "maxBytes must be a positive finite number", code: "bad-argument"))
            }
            let value = raw.doubleValue
            guard value.isFinite, value > 0 else {
                return .failure(PluginFetchError(
                    "maxBytes must be a positive finite number", code: "bad-argument"))
            }
            maxBytes = value >= Double(Int.max)
                ? WebFetchConstants.maxBytes
                : min(Int(value), WebFetchConstants.maxBytes)
        }
        guard let timeout = timeout(object) else {
            return .failure(PluginFetchError(
                "timeout must be a finite number greater than 0 (at most 120 seconds)",
                code: "bad-argument"))
        }
        return .success(PluginFetchRequest(
            url: url,
            method: string(object, "method") ?? "GET",
            headers: headers,
            body: body,
            cookies: cookies,
            redirect: redirect,
            maxBytes: maxBytes,
            timeout: timeout,
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
        if let text = value as? String { return checked(Data(text.utf8)) }
        guard let object = value as? [String: Any], object.count == 1,
              let key = object.keys.first else {
            return .failure(PluginFetchError(
                "body must be text, {base64}, {form}, {json} or {multipart}",
                code: "bad-argument"))
        }
        if key == "base64" {
            guard let base64 = object[key] as? String else {
                return .failure(PluginFetchError(
                    "body.base64 must be valid base64", code: "bad-argument"))
            }
            guard base64.utf8.count <= pluginMaxEncodedBodyBytes else {
                return .failure(PluginFetchError(
                    "the request body may be at most "
                        + "\(pluginMaxRequestBodyBytes / (1024 * 1024)) MB",
                    code: "too-large"))
            }
            guard let data = Data(base64Encoded: base64) else {
                return .failure(PluginFetchError(
                    "body.base64 must be valid base64", code: "bad-argument"))
            }
            return checked(data)
        }
        if key == "form" {
            guard let form = object[key] as? [String: Any],
                  form.values.allSatisfy({ $0 is String }) else {
                return .failure(PluginFetchError(
                    "body.form values must be strings", code: "bad-argument"))
            }
            setIfAbsent(&headers, "Content-Type", "application/x-www-form-urlencoded")
            return checked(Data(encodeForm(form).utf8))
        }
        if key == "json", let json = object[key] {
            setIfAbsent(&headers, "Content-Type", "application/json")
            // JSONSerialization can raise an Objective-C exception for values
            // such as Date. Validate the complete graph before encoding it.
            guard isJSONValue(json), let data = try? JSONSerialization.data(
                withJSONObject: json, options: [.fragmentsAllowed])
            else {
                return .failure(PluginFetchError(
                    "body.json is not valid JSON", code: "bad-argument"))
            }
            return checked(data)
        }
        if key == "multipart", let parts = object[key] as? [[String: Any]] {
            let boundary = "luna-\(UUID().uuidString)"
            setIfAbsent(&headers, "Content-Type", "multipart/form-data; boundary=\(boundary)")
            return encodeMultipart(parts, boundary: boundary, files: files)
                .map { Optional($0) }
        }
        return .failure(PluginFetchError(
            "body has an unsupported shape", code: "bad-argument"))
    }

    private static func checked(_ data: Data) -> Result<Data?, PluginFetchError> {
        guard data.count <= pluginMaxRequestBodyBytes else {
            return .failure(PluginFetchError(
                "the request body may be at most "
                    + "\(pluginMaxRequestBodyBytes / (1024 * 1024)) MB",
                code: "too-large"))
        }
        return .success(data)
    }

    private static func isJSONValue(_ value: Any) -> Bool {
        switch value {
        case is NSNull, is String, is NSNumber:
            return true
        case let values as [Any]:
            return values.allSatisfy(isJSONValue)
        case let values as [String: Any]:
            return values.values.allSatisfy(isJSONValue)
        default:
            return false
        }
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
        guard !parts.isEmpty else {
            return .failure(PluginFetchError(
                "body.multipart needs at least one part", code: "bad-argument"))
        }
        for part in parts {
            guard let name = part["name"] as? String, !name.isEmpty else {
                return .failure(PluginFetchError(
                    "each multipart part needs a name", code: "bad-argument"))
            }
            guard part["filename"] == nil || part["filename"] is String,
                  part["mime"] == nil || part["mime"] is String else {
                return .failure(PluginFetchError(
                    "multipart filename and mime must be strings", code: "bad-argument"))
            }
            var content: Data?
            var filename = part["filename"] as? String
            var mime = part["mime"] as? String
            let contentKeys = ["file", "text", "base64"].filter { part[$0] != nil }
            guard contentKeys.count == 1 else {
                return .failure(PluginFetchError(
                    "each multipart part needs exactly one file, text or base64 value",
                    code: "bad-argument"))
            }
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
                guard base64.utf8.count <= pluginMaxEncodedBodyBytes else {
                    return .failure(PluginFetchError(
                        "the multipart request body may be at most "
                            + "\(pluginMaxRequestBodyBytes / (1024 * 1024)) MB",
                        code: "too-large"))
                }
                guard let decoded = Data(base64Encoded: base64) else {
                    return .failure(PluginFetchError(
                        "multipart base64 must be valid base64", code: "bad-argument"))
                }
                content = decoded
            } else {
                return .failure(PluginFetchError(
                    "multipart file and text values must have the right shape",
                    code: "bad-argument"))
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
            guard body.count <= pluginMaxRequestBodyBytes else {
                return .failure(PluginFetchError(
                    "the multipart request body may be at most "
                        + "\(pluginMaxRequestBodyBytes / (1024 * 1024)) MB",
                    code: "too-large"))
            }
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        guard body.count <= pluginMaxRequestBodyBytes else {
            return .failure(PluginFetchError(
                "the multipart request body may be at most "
                    + "\(pluginMaxRequestBodyBytes / (1024 * 1024)) MB",
                code: "too-large"))
        }
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

    private static func timeout(_ object: [String: Any]) -> TimeInterval? {
        guard let raw = object["timeout"] else { return 20 }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0 else { return nil }
        return min(value, 120)
    }

    private static func stringDictionary(
        _ object: [String: Any], _ key: String
    ) -> [String: String] {
        guard let raw = object[key] as? [String: Any] else { return [:] }
        return raw.compactMapValues { $0 as? String }
    }
}
