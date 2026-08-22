//
//  XteinkDeviceClient.swift
//  Luna
//

import Foundation

/// HTTP client for the Xteink X3/X4 stock firmware's Wi-Fi file manager.
///
/// The e-reader serves plain HTTP on port 80 while it is awake on its Cloud
/// screen or Settings → App Connect, and sleeps off the network within seconds
/// of leaving them — every call here must expect the device to be absent and
/// fail fast. The protocol is the ESP32 web file manager the official app
/// talks to (community-documented; no custom firmware involved):
///
///   • `GET /status` — JSON with `device_type` (an `ESP32…` string), the probe.
///   • `POST /edit` — multipart upload; field name `data`, and the multipart
///     FILENAME is the destination path. The firmware also prepends that path
///     to `/push.txt`, its "Pushed Books" shelf manifest, which is what makes
///     an upload appear on the device's shelf.
///   • `PUT /edit path=<dir>/` — mkdir (trailing slash required).
///   • `GET /list?dir=<dir>` — directory listing, used to verify an upload's
///     size (the ESP32 truncates silently when interrupted).
///   • `DELETE /edit path=<p>` — used to remove a truncated upload.
public struct XteinkDeviceClient {

    /// Thrown when no candidate host answers the probe, or a transfer dies on a
    /// connection-level error. Conforms to `SendDeferralError`: an asleep
    /// e-reader is the normal state, not a delivery failure to back off from.
    public struct UnreachableError: Error, SendDeferralError {
        public init() {}
    }

    public enum UploadError: Error {
        /// The firmware answered, but not with success.
        case httpStatus(Int)
        /// The firmware reported the parent directory missing.
        case creationFailed
        /// The uploaded file is absent or truncated on the device.
        case verificationFailed(expectedBytes: Int, actualBytes: Int?)
    }

    /// One entry of `GET /list`.
    struct Entry: Equatable {
        let name: String
        let size: Int
        let isDirectory: Bool
    }

    /// The shelf directory uploads land in — the same one the community sync
    /// clients use, so books appear under the device's Pushed Books shelf.
    public static let pushDirectory = "/Pushed Books"

    /// Seconds allowed for the `/status` probe. Short: an absent device must
    /// not stall a sweep.
    static let probeTimeout: TimeInterval = 3
    /// Upload budget: base plus per-megabyte, sized for an ESP32-C3 receiving
    /// over Wi-Fi and committing to SD.
    static let uploadTimeoutBase: TimeInterval = 120
    static let uploadSecondsPerMB: TimeInterval = 45

    private let session: URLSession

    public init(session: URLSession = XteinkDeviceClient.makeSession()) {
        self.session = session
    }

    /// A session that fails fast instead of waiting for connectivity — the
    /// whole point of the probe is learning the device is asleep.
    public static func makeSession(
        configuration: URLSessionConfiguration = .ephemeral
    ) -> URLSession {
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    // MARK: - Discovery

    /// The first host that answers `/status` as an Xteink (an `ESP32…`
    /// `device_type`), or nil when none does.
    public func findDevice(among hosts: [String]) async -> String? {
        for host in hosts {
            if await isXteinkDevice(host: host) { return host }
        }
        return nil
    }

    func isXteinkDevice(host: String) async -> Bool {
        guard let url = url(host: host, path: "/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.probeTimeout
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceType = json["device_type"] as? String
        else { return false }
        return deviceType.hasPrefix("ESP32")
    }

    // MARK: - Upload

    /// Uploads a book onto the push shelf and verifies its size from the
    /// device's own listing, deleting a truncated copy rather than leaving a
    /// corrupt book on the shelf.
    public func uploadBook(_ data: Data, fileName: String, host: String) async throws {
        let destination = Self.pushDirectory + "/" + fileName
        try await ensurePushDirectory(host: host)
        try await upload(data, toPath: destination, host: host)
        // A listing that dies on connection propagates as UnreachableError —
        // the device slept mid-flow, which defers rather than fails the send.
        let listed = try await entries(inDirectory: Self.pushDirectory, host: host)
        let actual = listed.first {
            !$0.isDirectory && ($0.name == fileName || $0.name.hasSuffix("/" + fileName))
        }?.size
        guard actual == data.count else {
            try? await delete(path: destination, host: host)
            throw UploadError.verificationFailed(expectedBytes: data.count, actualBytes: actual)
        }
    }

    /// mkdir is idempotent enough for this flow: the firmware answers an
    /// existing directory with an error status, which is indistinguishable
    /// from harmless — the upload right after is what actually fails or works.
    private func ensurePushDirectory(host: String) async throws {
        _ = try? await editRequest(
            method: "PUT", form: ["path": Self.pushDirectory + "/"], host: host)
    }

    private func upload(_ data: Data, toPath destination: String, host: String) async throws {
        guard let url = url(host: host, path: "/edit") else { throw UnreachableError() }
        let boundary = "LunaXteink-" + UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.uploadTimeoutBase
            + Double(data.count) / 1_000_000 * Self.uploadSecondsPerMB

        var body = Data()
        body.append(contentsOf: Array("--\(boundary)\r\n".utf8))
        body.append(contentsOf: Array(
            "Content-Disposition: form-data; name=\"data\"; filename=\"\(destination)\"\r\n".utf8))
        body.append(contentsOf: Array("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(contentsOf: Array("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (responseData, response) = try await mappingConnectionErrors {
            try await session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw UploadError.httpStatus(status) }
        // The firmware reports a missing parent directory in the body, not the
        // status code.
        if String(decoding: responseData, as: UTF8.self).contains("Creation failed") {
            throw UploadError.creationFailed
        }
    }

    // MARK: - Listing / delete

    func entries(inDirectory directory: String, host: String) async throws -> [Entry] {
        guard var components = urlComponents(host: host, path: "/list") else {
            throw UnreachableError()
        }
        components.queryItems = [URLQueryItem(name: "dir", value: directory)]
        guard let url = components.url else { throw UnreachableError() }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.probeTimeout * 2
        let (data, response) = try await mappingConnectionErrors {
            try await session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UploadError.httpStatus(status) }
        // The firmware sends `text/json` with no charset; decode as UTF-8
        // explicitly so multibyte names survive.
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { object in
            guard let name = object["name"] as? String else { return nil }
            return Entry(
                name: name,
                size: object["size"] as? Int ?? 0,
                isDirectory: (object["type"] as? String) == "dir")
        }
    }

    func delete(path: String, host: String) async throws {
        _ = try await editRequest(method: "DELETE", form: ["path": path], host: host)
    }

    // MARK: - Plumbing

    @discardableResult
    private func editRequest(
        method: String, form: [String: String], host: String
    ) async throws -> Data {
        guard let url = url(host: host, path: "/edit") else { throw UnreachableError() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.probeTimeout * 2
        request.httpBody = Data(formEncoded(form).utf8)
        let (data, response) = try await mappingConnectionErrors {
            try await session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw UploadError.httpStatus(status) }
        return data
    }

    private func formEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }

    /// A device that answered the probe and then dropped off mid-transfer went
    /// back to sleep — that is deferral, not a failure to count against the
    /// item's retry budget.
    private func mappingConnectionErrors<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as URLError {
            switch error.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .networkConnectionLost, .notConnectedToInternet:
                throw UnreachableError()
            default:
                throw error
            }
        }
    }

    private func url(host: String, path: String) -> URL? {
        urlComponents(host: host, path: path)?.url
    }

    private func urlComponents(host: String, path: String) -> URLComponents? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = path
        return components
    }
}
