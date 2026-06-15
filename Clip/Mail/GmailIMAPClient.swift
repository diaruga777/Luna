//
//  GmailIMAPClient.swift
//  Clip
//

import Foundation
import Network
import os

/// One incoming message fetched from IMAP.
struct IncomingMessage: Equatable {
    let uid: Int
    let from: String
    let subject: String
    let body: String
    /// URLs detected in the body (plain text + any HTML hrefs).
    let urls: [URL]
}

/// Result of a fetch pass: the mailbox's UIDVALIDITY (so callers can detect a
/// mailbox reset), the new messages, and the highest UID seen.
struct IMAPFetchOutcome: Equatable {
    let uidValidity: Int
    let highestUID: Int
    let messages: [IncomingMessage]
}

/// Reads new messages from allowed senders. The concrete client speaks IMAP
/// over TLS; tests use a mock.
protocol IMAPFetching {
    /// Connects, logs in, and returns messages from `senders` with UID greater
    /// than `afterUID`. `knownUIDValidity` lets the client reset `afterUID` when
    /// the mailbox was recreated. Returns nil-equivalent empty when nothing new.
    func fetchNewMessages(
        account: String, password: String, senders: [String],
        afterUID: Int, knownUIDValidity: Int?
    ) async throws -> IMAPFetchOutcome
}

/// A hand-rolled minimal IMAP4rev1 client for Gmail (`imap.gmail.com:993`,
/// implicit TLS), authenticating with the same address + app password used for
/// send-to-Kindle. Speaks just enough: LOGIN → SELECT → UID SEARCH → UID FETCH.
final class GmailIMAPClient: IMAPFetching {

    static let host = "imap.gmail.com"
    static let port: UInt16 = 993

    struct IMAPError: Error, CustomStringConvertible {
        let step: String
        let detail: String
        var description: String { "IMAP \(step) failed: \(detail)" }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.hpiddy.clip.imap")
    private var receiveBuffer = Data()
    private var tagCounter = 0

    init() {
        let nwPort = NWEndpoint.Port(rawValue: Self.port) ?? .init(integerLiteral: 993)
        connection = NWConnection(host: NWEndpoint.Host(Self.host), port: nwPort, using: .tls)
    }

    func fetchNewMessages(
        account: String, password: String, senders: [String],
        afterUID: Int, knownUIDValidity: Int?
    ) async throws -> IMAPFetchOutcome {
        defer { connection.cancel() }
        try await connect()
        _ = try await readLine() // server greeting (* OK ...)

        try await run("LOGIN \(Self.quoted(account)) \(Self.quoted(password))", step: "login")
        let selectResponse = try await run("SELECT INBOX", step: "select")
        let uidValidity = Self.parseBracketValue("UIDVALIDITY", in: selectResponse.lines) ?? 0
        let uidNext = Self.parseBracketValue("UIDNEXT", in: selectResponse.lines) ?? 1

        // First run (or a mailbox reset) starts from "now" so we don't import the
        // entire backlog — only mail that arrives after the feature is enabled.
        var startUID = afterUID + 1
        if afterUID == 0 || knownUIDValidity != uidValidity {
            return IMAPFetchOutcome(uidValidity: uidValidity, highestUID: uidNext - 1, messages: [])
        }

        var messages: [IncomingMessage] = []
        var highestUID = afterUID
        for sender in senders {
            let search = try await run(
                "UID SEARCH UID \(startUID):* FROM \(Self.quoted(sender))", step: "search")
            for uid in Self.parseSearchUIDs(search.lines) {
                let fetch = try await run(
                    "UID FETCH \(uid) (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)] BODY.PEEK[TEXT])",
                    step: "fetch")
                guard fetch.literals.count >= 2 else { continue }
                let headers = Self.parseHeaders(String(decoding: fetch.literals[0], as: UTF8.self))
                let body = String(decoding: fetch.literals[1], as: UTF8.self)
                messages.append(IncomingMessage(
                    uid: uid,
                    from: headers["from"] ?? sender,
                    subject: headers["subject"] ?? "",
                    body: body,
                    urls: Self.extractURLs(from: body)))
                highestUID = max(highestUID, uid)
                // Courtesy: mark read so it doesn't show unread in Gmail. Dedup
                // relies on UID, not this.
                _ = try? await run("UID STORE \(uid) +FLAGS (\\Seen)", step: "store")
            }
        }
        startUID = highestUID + 1
        try? await run("LOGOUT", step: "logout")
        return IMAPFetchOutcome(
            uidValidity: uidValidity, highestUID: highestUID, messages: messages)
    }

    // MARK: - Command loop

    private struct Response {
        let lines: [String]
        let literals: [Data]
    }

    /// Sends one tagged command and collects untagged data lines + literals up
    /// to the tagged completion line. Throws on NO/BAD.
    @discardableResult
    private func run(_ command: String, step: String) async throws -> Response {
        tagCounter += 1
        let tag = "a\(tagCounter)"
        try await send(Data("\(tag) \(command)\r\n".utf8))

        var lines: [String] = []
        var literals: [Data] = []
        while true {
            var line = try await readLine()
            while let count = Self.trailingLiteralCount(line) {
                literals.append(try await readBytes(count))
                line += try await readLine()
            }
            if line.hasPrefix("\(tag) ") {
                let upper = line.uppercased()
                guard upper.contains(" OK") else {
                    throw IMAPError(step: step, detail: line)
                }
                return Response(lines: lines, literals: literals)
            }
            lines.append(line)
        }
    }

    // MARK: - Pure parsing (unit-tested)

    /// IMAP quoted string (wraps in quotes, escapes `\` and `"`).
    static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Trailing `{123}` literal byte count at the end of a line, if present.
    static func trailingLiteralCount(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        let digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        return Int(digits)
    }

    /// Extracts a `[KEY value]` integer from SELECT response lines.
    static func parseBracketValue(_ key: String, in lines: [String]) -> Int? {
        for line in lines {
            guard let range = line.range(of: "[\(key) ") else { continue }
            let rest = line[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            if let value = Int(digits) { return value }
        }
        return nil
    }

    /// UIDs from an untagged `* SEARCH 1 2 3` line.
    static func parseSearchUIDs(_ lines: [String]) -> [Int] {
        for line in lines {
            let upper = line.uppercased()
            guard upper.hasPrefix("* SEARCH") else { continue }
            return line.split(separator: " ").compactMap { Int($0) }
        }
        return []
    }

    /// Parses `Key: value` headers (lowercased keys; unfolds simple folds).
    static func parseHeaders(_ raw: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        for rawLine in raw.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let first = line.first, first == " " || first == "\t", let key = currentKey {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
                currentKey = key
            }
        }
        return headers
    }

    /// URLs in a message body: plain-text links via NSDataDetector plus any
    /// `href="…"` targets in HTML parts.
    static func extractURLs(from body: String) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        func add(_ string: String) {
            guard let url = URL(string: string), url.scheme?.hasPrefix("http") == true,
                  seen.insert(url.absoluteString).inserted else { return }
            found.append(url)
        }
        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(body.startIndex..., in: body)
            for match in detector.matches(in: body, range: range) {
                if let url = match.url { add(url.absoluteString) }
            }
        }
        // hrefs (links that aren't bare URLs the detector would miss).
        var searchRange = body.startIndex..<body.endIndex
        while let hrefRange = body.range(of: "href=\"", options: .caseInsensitive, range: searchRange),
              let closeQuote = body[hrefRange.upperBound...].firstIndex(of: "\"") {
            add(String(body[hrefRange.upperBound..<closeQuote]))
            searchRange = closeQuote..<body.endIndex
        }
        return found
    }

    // MARK: - Connection primitives

    private func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { state in
                let result: Result<Void, Error>
                switch state {
                case .ready: result = .success(())
                case .failed(let error), .waiting(let error): result = .failure(error)
                default: return
                }
                let isFirst = resumed.withLock { done in defer { done = true }; return !done }
                guard isFirst else { return }
                continuation.resume(with: result)
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let lineEnd = receiveBuffer.firstRange(of: Data("\r\n".utf8)) {
                let lineData = receiveBuffer.subdata(in: receiveBuffer.startIndex..<lineEnd.lowerBound)
                receiveBuffer.removeSubrange(receiveBuffer.startIndex..<lineEnd.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            try await fill()
        }
    }

    private func readBytes(_ count: Int) async throws -> Data {
        while receiveBuffer.count < count { try await fill() }
        let data = receiveBuffer.prefix(count)
        receiveBuffer.removeFirst(count)
        return Data(data)
    }

    private func fill() async throws {
        let chunk: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
                _ = isComplete
            }
        }
        guard !chunk.isEmpty else { throw IMAPError(step: "read", detail: "connection closed") }
        receiveBuffer.append(chunk)
    }
}
