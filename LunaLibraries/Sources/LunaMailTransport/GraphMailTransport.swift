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
        // A mail endpoint, NOT /me: the requested scopes are Mail.*/
        // MailboxSettings only — /me needs User.Read and would 403 a
        // perfectly valid token.
        _ = try await get("https://graph.microsoft.com/v1.0/me/mailFolders/inbox")
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
        // No isRead filter: the auto-installed Luna inbox rule marks shares read
        // on arrival (and the user may simply read one first) — an unread-only
        // query would never return them. The receivedDateTime cursor dedupes.
        //
        // Newsletter subject filters can't run server-side (Graph's mail $filter
        // supports eq/startswith but not contains), so when any exist — and a
        // cursor is anchored to bound the window — everything since the cursor
        // is fetched and matched client-side, mirroring the IMAP path's
        // header-OR-sender-OR-subject semantics.
        let matchClientSide = !extraSubjects.isEmpty && !(cursor?.token ?? "").isEmpty
        var interest = [String]()
        if !matchClientSide {
            interest = ["startswith(subject,'\(Self.odataEscaped(FilterGuide.subjectMatch))')"]
            interest += extraSenders.map {
                "from/emailAddress/address eq '\(Self.odataEscaped($0))'"
            }
        }
        let dateClause = (cursor?.token).flatMap { $0.isEmpty ? nil : "receivedDateTime gt \($0)" }

        // One request PER interest clause rather than OR-ing them into a single
        // $filter: Graph's mail API throws InefficientFilter when an OR'd
        // multi-property filter is combined with $orderby (unlike Azure AD's
        // directory-object endpoints, ConsistencyLevel/$count doesn't help
        // here — there's no "advanced query" mode for /me/messages). Each
        // single-clause request stays filter+orderby on an indexed property,
        // which Graph accepts; results are merged/deduped by id below —
        // mirroring the IMAP path's per-clause unioned searches.
        var byID: [String: MessageWire] = [:]
        for clause in (matchClientSide ? [nil] : interest.map { Optional($0) }) {
            var clauses = [String]()
            if let clause { clauses.append(clause) }
            if let dateClause { clauses.append(dateClause) }
            var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")!
            components.queryItems = [
                URLQueryItem(name: "$select",
                             value: "id,subject,from,receivedDateTime,body,internetMessageHeaders"),
                URLQueryItem(name: "$filter", value: clauses.joined(separator: " and ")),
                URLQueryItem(name: "$top", value: "25"),
                URLQueryItem(name: "$orderby", value: "receivedDateTime asc"),
            ]
            let data = try await get(components.url!.absoluteString)
            let page = try JSONDecoder().decode(MessagesPage.self, from: data)
            for wire in page.value { byID[wire.id] = wire }
        }

        var messages: [FetchedMessage] = []
        var newestDate = cursor?.token ?? ""
        for wire in byID.values.sorted(by: { ($0.receivedDateTime ?? "") < ($1.receivedDateTime ?? "") }) {
            newestDate = max(newestDate, wire.receivedDateTime ?? "")
            let headers = wire.headerMap
            let bodyContent = wire.body?.content ?? ""
            let marker = StreamIMAPClient.marker(headers: headers, body: bodyContent)
            let message = FetchedMessage(
                id: wire.id, uid: nil,
                from: wire.fromAddress, subject: wire.subject ?? "",
                date: wire.receivedDateTime ?? "", headers: headers,
                bodyText: bodyContent, marker: marker)
            if matchClientSide {
                guard Self.matches(message, senders: extraSenders, subjects: extraSubjects) else {
                    continue
                }
            }
            messages.append(message)
        }
        if newestDate.isEmpty, byID.isEmpty {
            // First run with nothing of interest yet: anchor the cursor at now
            // so the client-side subject window above can activate — otherwise
            // an account with no Luna mail would never establish a cursor.
            newestDate = ISO8601DateFormatter().string(from: Date())
        }
        return FetchResult(messages: messages, cursor: MailCursor(token: newestDate))
    }

    /// The IMAP path's interest test: a Luna share marker, a sender match, or a
    /// subject substring match (both case-insensitive substring, like IMAP
    /// FROM/SUBJECT search).
    static func matches(
        _ message: FetchedMessage, senders: [String], subjects: [String]
    ) -> Bool {
        if message.marker != nil { return true }
        if message.subject.hasPrefix(FilterGuide.subjectMatch) { return true }
        let from = message.from.lowercased()
        if senders.contains(where: { !$0.isEmpty && from.contains($0.lowercased()) }) {
            return true
        }
        let subject = message.subject.lowercased()
        return subjects.contains(where: { !$0.isEmpty && subject.contains($0.lowercased()) })
    }

    /// OData string-literal escaping (single quotes double).
    static func odataEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
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
            "conditions": ["subjectContains": [FilterGuide.subjectMatch]],
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
            if let http = response as? HTTPURLResponse,
               Self.authenticationFailure(statusCode: http.statusCode, body: data) {
                throw EmailAuthenticationError(
                    issue: .authorizationExpired,
                    detail: "Microsoft token refresh was rejected.")
            }
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
            if let http = response as? HTTPURLResponse,
               Self.authenticationFailure(statusCode: http.statusCode, body: data) {
                throw EmailAuthenticationError(
                    issue: .authorizationExpired,
                    detail: "Microsoft Graph rejected the saved authorization.")
            }
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
            if Self.authenticationFailure(statusCode: http.statusCode, body: data) {
                throw EmailAuthenticationError(
                    issue: .authorizationExpired,
                    detail: "Microsoft Graph rejected the saved authorization.")
            }
            throw GraphError(detail: "\(step) failed (\(http.statusCode)): "
                + "\(String(decoding: data, as: UTF8.self).prefix(200))")
        }
    }

    /// Only responses that explicitly describe an authentication/authorization
    /// rejection are eligible to revive recovery UI. Rate limits and 5xx
    /// responses intentionally remain transient.
    static func authenticationFailure(statusCode: Int, body: Data) -> Bool {
        if statusCode == 401 { return true }
        guard statusCode == 400 || statusCode == 403 else { return false }
        let detail = String(decoding: body, as: UTF8.self).lowercased()
        return [
            "invalid_grant",
            "interaction_required",
            "invalidauthenticationtoken",
            "authenticationfailure",
            "erroraccessdenied",
        ].contains(where: detail.contains)
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
