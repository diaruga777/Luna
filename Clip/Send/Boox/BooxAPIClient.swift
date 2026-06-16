//
//  BooxAPIClient.swift
//  Clip
//

import Foundation

/// A Send2Boox API failure, with the path + detail for diagnosis.
struct BooxAPIError: Error, CustomStringConvertible {
    let path: String
    let detail: String
    var description: String { "Boox \(path) failed: \(detail)" }
}

/// The Onyx response envelope — useful payload sits under `data`.
struct BooxEnvelope<T: Decodable>: Decodable {
    let data: T?
    let message: String?
}

// MARK: - Response payloads

struct BooxLoginData: Decodable { let token: String }

struct BooxUserData: Decodable {
    let uid: String
    // The API may encode uid as a string or a number — accept both.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decode(String.self, forKey: .uid) {
            uid = string
        } else if let number = try? container.decode(Int.self, forKey: .uid) {
            uid = String(number)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .uid, in: container, debugDescription: "uid is neither String nor Int")
        }
    }
    enum CodingKeys: String, CodingKey { case uid }
}

struct BooxBucketsData: Decodable {
    let onyxCloud: Bucket
    enum CodingKeys: String, CodingKey { case onyxCloud = "onyx-cloud" }
    struct Bucket: Decodable {
        let bucket: String
        let aliEndpoint: String
    }
}

/// Alibaba OSS temporary credentials (note the capitalized JSON keys).
struct BooxSTSData: Decodable {
    let accessKeyId: String
    let accessKeySecret: String
    let securityToken: String
    enum CodingKeys: String, CodingKey {
        case accessKeyId = "AccessKeyId"
        case accessKeySecret = "AccessKeySecret"
        case securityToken = "SecurityToken"
    }
}

/// Thin client for the Send2Boox JSON API at `https://{host}/api/1/…`. Mirrors
/// the reference client's conventions: a Bearer token when present, and a JSON
/// body implies POST.
final class BooxAPIClient {

    let host: String
    private let session: URLSession

    init(host: String, session: URLSession = .shared) {
        self.host = host
        self.session = session
    }

    private func makeRequest(
        path: String, method: String, token: String?, body: [String: Any]?
    ) throws -> URLRequest {
        guard let url = URL(string: "https://\(host)/api/1/\(path)") else {
            throw BooxAPIError(path: path, detail: "bad URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            if method == "GET" { request.httpMethod = "POST" } // a body implies POST
        }
        return request
    }

    /// Issues the request and decodes the envelope's `data` into `T`, throwing
    /// when the HTTP status is non-2xx or `data` is absent.
    func value<T: Decodable>(
        path: String, method: String = "GET", token: String? = nil,
        body: [String: Any]? = nil, as type: T.Type
    ) async throws -> T {
        let request = try makeRequest(path: path, method: method, token: token, body: body)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, path: path)
        let envelope = try JSONDecoder().decode(BooxEnvelope<T>.self, from: data)
        guard let value = envelope.data else {
            throw BooxAPIError(path: path, detail: envelope.message ?? "no data in response")
        }
        return value
    }

    /// Issues a request whose response payload is irrelevant (just checks success).
    func send(
        path: String, method: String = "POST", token: String? = nil, body: [String: Any]?
    ) async throws {
        let request = try makeRequest(path: path, method: method, token: token, body: body)
        let (_, response) = try await session.data(for: request)
        try Self.checkStatus(response, path: path)
    }

    private static func checkStatus(_ response: URLResponse, path: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BooxAPIError(path: path, detail: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BooxAPIError(path: path, detail: "HTTP \(http.statusCode)")
        }
    }
}
