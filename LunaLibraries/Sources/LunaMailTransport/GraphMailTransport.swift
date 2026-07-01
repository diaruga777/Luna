//
//  GraphMailTransport.swift
//  LunaMailTransport
//

import Foundation
import LunaMailAccount

/// `EmailTransport` for Outlook/Hotmail over Microsoft Graph. Consumer Microsoft
/// accounts no longer allow app-password IMAP/SMTP, so this is the only viable
/// path (send + read + inbox rules, all free). Sends the same raw MIME the
/// app-password backend does, base64-encoded to `/me/sendMail`.
public struct GraphMailTransport: EmailTransport {

    private let store: EmailAccountStore
    private let clientID: String

    public struct GraphError: Error, CustomStringConvertible {
        public let detail: String
        public var description: String { detail }
    }

    public init(store: EmailAccountStore = .shared, clientID: String = MicrosoftOAuth.clientID) {
        self.store = store
        self.clientID = clientID
    }

    // MARK: - EmailTransport

    public func verifyCredentials() async throws {
        _ = try await get("https://graph.microsoft.com/v1.0/me")
    }

    public func send(_ email: OutgoingEmail) async throws {
        // Graph accepts a raw MIME message base64-encoded with Content-Type text/plain.
        let token = try await accessToken()
        var request = URLRequest(url: url("https://graph.microsoft.com/v1.0/me/sendMail"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(email.rawMIME.base64EncodedString().utf8)
        try await send(request, expect: 202, step: "sendMail")
    }

    public func fetchShares(
        after cursor: MailCursor?, extraSenders: [String], extraSubjects: [String]
    ) async throws -> FetchResult {
        var filter = "isRead eq false and startswith(subject,'From Luna:')"
        if let token = cursor?.token, !token.isEmpty {
            filter += " and receivedDateTime gt \(token)"
        }
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "$select",
                         value: "id,subject,from,receivedDateTime,body,internetMessageHeaders"),
            URLQueryItem(name: "$filter", value: filter),
            URLQueryItem(name: "$top", value: "25"),
            URLQueryItem(name: "$orderby", value: "receivedDateTime asc"),
        ]
        let data = try await get(components.url!.absoluteString)

        let page = try JSONDecoder().decode(MessagesPage.self, from: data)
        var messages: [FetchedMessage] = []
        var newestDate = cursor?.token ?? ""
        for wire in page.value {
            newestDate = max(newestDate, wire.receivedDateTime ?? "")
            let headers = wire.headerMap
            let bodyContent = wire.body?.content ?? ""
            let marker = StreamIMAPClient.marker(headers: headers, body: bodyContent)
            messages.append(FetchedMessage(
                id: wire.id, uid: nil,
                from: wire.fromAddress, subject: wire.subject ?? "",
                date: wire.receivedDateTime ?? "", headers: headers,
                bodyText: bodyContent, marker: marker))
        }
        return FetchResult(messages: messages, cursor: MailCursor(token: newestDate))
    }

    public func markRead(_ messageIDs: [String]) async throws {
        let token = try await accessToken()
        for id in messageIDs {
            var request = URLRequest(url: url("https://graph.microsoft.com/v1.0/me/messages/\(id)"))
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"isRead":true}"#.utf8)
            try? await send(request, expect: 200, step: "markRead")
        }
    }

    public func createLunaFilter() async throws -> FilterOutcome {
        let token = try await accessToken()
        var request = URLRequest(
            url: url("https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messageRules"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let rule: [String: Any] = [
            "displayName": "Luna",
            "sequence": 1,
            "isEnabled": true,
            "conditions": ["subjectContains": ["From Luna:"]],
            "actions": ["markAsRead": true, "stopProcessingRules": true],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: rule)
        do {
            try await send(request, expect: 201, step: "messageRules")
            return .created
        } catch {
            return .failed("\(error)")
        }
    }

    // MARK: - Token handling

    private func accessToken() async throws -> String {
        guard case .oauth(let tokens)? = store.credential else {
            throw GraphError(detail: "Not signed in to Outlook.")
        }
        if !tokens.isExpired() { return tokens.accessToken }
        guard !clientID.isEmpty else { throw GraphError(detail: "Missing Microsoft client id.") }

        var request = URLRequest(url: url(MicrosoftOAuth.tokenEndpoint))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = MicrosoftOAuth.formEncode(
            MicrosoftOAuth.refreshParameters(clientID: clientID, refreshToken: tokens.refreshToken))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GraphError(detail: "Token refresh failed.")
        }
        let wire = try JSONDecoder().decode(TokenWire.self, from: data)
        let refreshed = OAuthTokens(
            accessToken: wire.access_token,
            refreshToken: wire.refresh_token ?? tokens.refreshToken,
            expiry: Date().addingTimeInterval(wire.expires_in))
        store.updateOAuthTokens(refreshed)
        return refreshed.accessToken
    }

    // MARK: - HTTP helpers

    private func url(_ string: String) -> URL {
        // All call sites pass constant, well-formed URLs.
        URL(string: string)!
    }

    private func get(_ string: String) async throws -> Data {
        let token = try await accessToken()
        var request = URLRequest(url: url(string))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GraphError(detail: "Graph GET failed: \(String(decoding: data, as: UTF8.self).prefix(200))")
        }
        return data
    }

    private func send(_ request: URLRequest, expect status: Int, step: String) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GraphError(detail: "\(step): no response")
        }
        guard http.statusCode == status || (200..<300).contains(http.statusCode) else {
            throw GraphError(detail: "\(step) failed (\(http.statusCode)): "
                + "\(String(decoding: data, as: UTF8.self).prefix(200))")
        }
    }

    // MARK: - Wire types

    private struct TokenWire: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
    }

    private struct MessagesPage: Decodable { let value: [MessageWire] }

    private struct MessageWire: Decodable {
        let id: String
        let subject: String?
        let receivedDateTime: String?
        let from: Recipient?
        let body: Body?
        let internetMessageHeaders: [Header]?

        struct Recipient: Decodable { let emailAddress: Address? }
        struct Address: Decodable { let name: String?; let address: String? }
        struct Body: Decodable { let contentType: String?; let content: String? }
        struct Header: Decodable { let name: String; let value: String? }

        var fromAddress: String {
            guard let a = from?.emailAddress else { return "" }
            if let name = a.name, let addr = a.address { return "\(name) <\(addr)>" }
            return a.address ?? ""
        }

        /// Lowercased header map (matching the IMAP path's convention).
        var headerMap: [String: String] {
            var map: [String: String] = [:]
            for header in internetMessageHeaders ?? [] {
                map[header.name.lowercased()] = header.value ?? ""
            }
            return map
        }
    }
}
