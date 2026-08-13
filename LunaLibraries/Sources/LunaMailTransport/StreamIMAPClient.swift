//
//  StreamIMAPClient.swift
//  LunaMailTransport
//

import Foundation
import LunaMail
import LunaMailAccount

/// Minimal IMAP4rev1 client over `MailStream` (implicit TLS on 993). Speaks just
/// enough to find + read Luna shares (and matched newsletter senders/subjects)
/// and to flag messages `\Seen`. Reuses `GmailIMAPClient`'s pure parsers.
struct StreamIMAPClient {

    struct IMAPError: Error, CustomStringConvertible {
        let step: String
        let detail: String
        var description: String { "IMAP \(step) failed: \(detail)" }
    }

    let host: String
    let port: Int
    /// Cap on bytes fetched per message — enough for an article, bounded so a
    /// huge newsletter can't blow up memory.
    static let maxFetchBytes = 512 * 1024

    // MARK: - Public operations

    /// Logs in and returns nothing — proves the credential works (for `verify`).
    func login(username: String, password: String) async throws {
        let session = try await Session.open(host: host, port: port)
        defer { session.close() }
        try await session.login(username: username, password: password)
        _ = try? await session.run("LOGOUT", step: "logout")
    }

    /// Finds messages with UID greater than `after.uid` matching the Luna header,
    /// any `senders` (FROM), or any `subjects` (SUBJECT). Returns them plus the
    /// updated cursor. On first run / UIDVALIDITY change, imports nothing and
    /// just anchors the cursor at the current tip (no backlog import).
    func fetchShares(
        username: String, password: String,
        after cursor: MailCursor, senders: [String], subjects: [String]
    ) async throws -> FetchResult {
        let session = try await Session.open(host: host, port: port)
        defer { session.close() }
        try await session.login(username: username, password: password)

        let select = try await session.run("SELECT INBOX", step: "select")
        let uidValidity = GmailIMAPClient.parseBracketValue("UIDVALIDITY", in: select.lines) ?? 0
        let uidNext = GmailIMAPClient.parseBracketValue("UIDNEXT", in: select.lines) ?? 1

        // An `.imap` cursor whose validity still matches resumes from its uid;
        // `.fresh`, a stray `.graph` cursor (e.g. the account switched
        // providers), or a UIDVALIDITY change (the mailbox renumbered its
        // UIDs) all mean the same thing here — nothing to resume from.
        let afterUID: Int
        switch cursor {
        case .imap(let uid, let storedValidity) where storedValidity == uidValidity:
            afterUID = uid
        case .imap, .fresh, .graph:
            afterUID = 0
        }

        if afterUID == 0 {
            _ = try? await session.run("LOGOUT", step: "logout")
            return FetchResult(
                messages: [],
                cursor: .imap(uid: uidNext - 1, uidValidity: uidValidity))
        }

        let start = afterUID + 1
        var matched = Set<Int>()
        // Luna shares — server-side match on the presence of our header. Also
        // fall back to the human-readable subject prefix: Gmail's IMAP SEARCH
        // is backed by its own index rather than a literal RFC 3501 header
        // scan and can silently miss custom (X-*) headers, so the header
        // search alone isn't reliable — mirrors GraphMailTransport.matches's
        // subject-prefix fallback.
        matched.formUnion(try await search(
            session, "UID SEARCH UID \(start):* HEADER \(GmailIMAPClient.quoted(LunaShareMarker.headerName)) \"\"",
            afterUID: afterUID))
        matched.formUnion(try await search(
            session, "UID SEARCH UID \(start):* SUBJECT \(GmailIMAPClient.quoted(FilterGuide.subjectMatch))",
            afterUID: afterUID))
        for sender in senders {
            matched.formUnion(try await search(
                session, "UID SEARCH UID \(start):* FROM \(GmailIMAPClient.quoted(sender))",
                afterUID: afterUID))
        }
        for subject in subjects {
            matched.formUnion(try await search(
                session, "UID SEARCH UID \(start):* SUBJECT \(GmailIMAPClient.quoted(subject))",
                afterUID: afterUID))
        }

        var messages: [FetchedMessage] = []
        var highestUID = afterUID
        for uid in matched.sorted() {
            let fetch = try await session.run(
                "UID FETCH \(uid) (UID BODY.PEEK[]<0.\(Self.maxFetchBytes)>)", step: "fetch")
            highestUID = max(highestUID, uid)
            guard let raw = fetch.literals.first else { continue }
            let rawString = String(decoding: raw, as: UTF8.self)
            let (headerText, body) = GmailIMAPClient.splitMessage(rawString)
            let headers = GmailIMAPClient.parseHeaders(headerText)
            let marker = Self.marker(headers: headers, body: body)
            messages.append(FetchedMessage(
                id: String(uid), uid: uid,
                from: headers["from"] ?? "", subject: headers["subject"] ?? "",
                date: headers["date"] ?? "", headers: headers, bodyText: body, marker: marker))
        }
        _ = try? await session.run("LOGOUT", step: "logout")
        return FetchResult(
            messages: messages, cursor: .imap(uid: highestUID, uidValidity: uidValidity))
    }

    /// Flags the given UIDs `\Seen` in INBOX (best-effort).
    func markSeen(username: String, password: String, uids: [Int]) async throws {
        guard !uids.isEmpty else { return }
        let session = try await Session.open(host: host, port: port)
        defer { session.close() }
        try await session.login(username: username, password: password)
        try await session.run("SELECT INBOX", step: "select")
        let set = uids.map(String.init).joined(separator: ",")
        _ = try? await session.run("UID STORE \(set) +FLAGS (\\Seen)", step: "store")
        _ = try? await session.run("LOGOUT", step: "logout")
    }

    // MARK: - Helpers

    /// Recovers a Luna marker from the header (preferred) or the hidden body block.
    static func marker(headers: [String: String], body: String) -> LunaShareMarker? {
        if let value = headers[LunaShareMarker.headerName.lowercased()],
           let marker = LunaShareMarker.from(headerValue: value) {
            return marker
        }
        return LunaShareMarker.from(htmlBody: body)
    }

    private func search(_ session: Session, _ command: String, afterUID: Int) async throws -> [Int] {
        let response = try await session.run(command, step: "search")
        return GmailIMAPClient.newSearchUIDs(response.lines, afterUID: afterUID)
    }

    // MARK: - Session (command loop over MailStream)

    final class Session {
        private let stream: MailStream
        private var tag = 0

        private init(stream: MailStream) { self.stream = stream }

        static func open(host: String, port: Int) async throws -> Session {
            let stream = MailStream(host: host, port: port)
            stream.startTLS() // IMAP is implicit TLS from connect.
            do {
                _ = try await stream.readLine() // server greeting
            } catch {
                // The callers' `defer { session.close() }` only covers failures
                // AFTER open returns — close here or every failed poll against
                // an unreachable server leaks an open stream task.
                stream.close()
                throw error
            }
            return Session(stream: stream)
        }

        func login(username: String, password: String) async throws {
            do {
                try await run(
                    "LOGIN \(GmailIMAPClient.quoted(username)) \(GmailIMAPClient.quoted(password))",
                    step: "login")
            } catch let error as IMAPError {
                // Reaching a tagged NO/BAD reply proves the network and TLS
                // connection worked; a rejected LOGIN is therefore a saved
                // credential problem, not a transient connectivity failure.
                throw EmailAuthenticationError(
                    issue: .credentialsRejected, detail: error.description)
            }
        }

        func close() { stream.close() }

        struct Response { let lines: [String]; let literals: [Data] }

        @discardableResult
        func run(_ command: String, step: String) async throws -> Response {
            tag += 1
            let tagString = "a\(tag)"
            try await stream.writeLine("\(tagString) \(command)")

            var lines: [String] = []
            var literals: [Data] = []
            while true {
                var line = try await stream.readLine()
                while let count = GmailIMAPClient.trailingLiteralCount(line) {
                    literals.append(try await stream.readBytes(count))
                    line += try await stream.readLine()
                }
                if line.hasPrefix("\(tagString) ") {
                    guard line.uppercased().contains(" OK") else {
                        throw IMAPError(step: step, detail: line)
                    }
                    return Response(lines: lines, literals: literals)
                }
                lines.append(line)
            }
        }
    }
}
