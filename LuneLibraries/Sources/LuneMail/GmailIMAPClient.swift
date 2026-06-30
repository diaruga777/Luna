//
//  GmailIMAPClient.swift
//  Lune
//

import LuneStorage
import Foundation
import Network
import os

/// One incoming message fetched from IMAP.
public struct IncomingMessage: Equatable {
    public let uid: Int
    public let from: String
    public let subject: String
    public let date: String
    /// Top-level `Content-Type` (carries the multipart boundary, if any).
    public let contentType: String
    /// Top-level `Content-Transfer-Encoding` (base64 / quoted-printable / …).
    public let transferEncoding: String
    public let body: String
    /// URLs detected in the body (plain text + any HTML hrefs).
    public let urls: [URL]

    public init(uid: Int, from: String, subject: String, date: String, contentType: String,
                transferEncoding: String, body: String, urls: [URL]) {
        self.uid = uid
        self.from = from
        self.subject = subject
        self.date = date
        self.contentType = contentType
        self.transferEncoding = transferEncoding
        self.body = body
        self.urls = urls
    }
}

/// Result of a fetch pass: the mailbox's UIDVALIDITY (so callers can detect a
/// mailbox reset), the new messages, and the highest UID seen.
public struct IMAPFetchOutcome: Equatable {
    public let uidValidity: Int
    public let highestUID: Int
    public let messages: [IncomingMessage]

    public init(uidValidity: Int, highestUID: Int, messages: [IncomingMessage]) {
        self.uidValidity = uidValidity
        self.highestUID = highestUID
        self.messages = messages
    }
}

/// Reads new messages from allowed senders. The concrete client speaks IMAP
/// over TLS; tests use a mock.
public protocol IMAPFetching {
    /// Connects, logs in, and returns messages with UID greater than `afterUID`
    /// that match any allowed `senders` (FROM) OR any `subjectFilters` (SUBJECT,
    /// case-insensitive substring). `knownUIDValidity` lets the client reset
    /// `afterUID` when the mailbox was recreated. Empty when nothing new.
    func fetchNewMessages(
        account: String, password: String, senders: [String], subjectFilters: [String],
        afterUID: Int, knownUIDValidity: Int?
    ) async throws -> IMAPFetchOutcome
}

/// A hand-rolled minimal IMAP4rev1 client for Gmail (`imap.gmail.com:993`,
/// implicit TLS), authenticating with the same address + app password used for
/// send-to-Kindle. Speaks just enough: LOGIN → SELECT → UID SEARCH → UID FETCH.
public final class GmailIMAPClient: IMAPFetching {

    public static let host = "imap.gmail.com"
    public static let port: UInt16 = 993
    /// Cap on the raw bytes fetched per message — enough for an article's text,
    /// bounded so a huge newsletter can't blow up memory.
    public static let maxFetchBytes = 512 * 1024
    /// Hard ceiling on the whole exchange. A stalled socket can't be interrupted
    /// by `Task.cancel` alone (an `NWConnection` receive continuation just parks),
    /// so we cap it and cancel the connection to unblock.
    public static let timeoutSeconds: UInt64 = 30

    public struct IMAPError: Error, CustomStringConvertible {
        public let step: String
        public let detail: String
        public var description: String { "IMAP \(step) failed: \(detail)" }

        public init(step: String, detail: String) {
            self.step = step
            self.detail = detail
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.hpiddy.lune.imap")
    private var receiveBuffer = Data()
    private var tagCounter = 0

    public init() {
        let nwPort = NWEndpoint.Port(rawValue: Self.port) ?? .init(integerLiteral: 993)
        connection = NWConnection(host: NWEndpoint.Host(Self.host), port: nwPort, using: .tls)
    }

    public func fetchNewMessages(
        account: String, password: String, senders: [String], subjectFilters: [String],
        afterUID: Int, knownUIDValidity: Int?
    ) async throws -> IMAPFetchOutcome {
        let watchdog = Task { [connection] in
            try? await Task.sleep(nanoseconds: Self.timeoutSeconds * 1_000_000_000)
            connection.cancel()
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try await performFetch(
                account: account, password: password, senders: senders,
                subjectFilters: subjectFilters, afterUID: afterUID, knownUIDValidity: knownUIDValidity)
        } onCancel: {
            connection.cancel()
        }
    }

    private func performFetch(
        account: String, password: String, senders: [String], subjectFilters: [String],
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
        let startUID = afterUID + 1
        if afterUID == 0 || knownUIDValidity != uidValidity {
            return IMAPFetchOutcome(uidValidity: uidValidity, highestUID: uidNext - 1, messages: [])
        }

        // Collect UIDs matching any allowed sender (FROM) or subject filter
        // (SUBJECT), deduped — a message may match more than one criterion.
        var matchedUIDs = Set<Int>()
        for sender in senders {
            let search = try await run(
                "UID SEARCH UID \(startUID):* FROM \(Self.quoted(sender))", step: "search")
            let uids = Self.newSearchUIDs(search.lines, afterUID: afterUID)
            DiagnosticLog.shared.record(
                "imap: sender \(sender) → \(uids.count) new uid(s) (after uid \(afterUID))",
                category: "mail")
            matchedUIDs.formUnion(uids)
        }
        for filter in subjectFilters {
            let search = try await run(
                "UID SEARCH UID \(startUID):* SUBJECT \(Self.quoted(filter))", step: "search")
            let uids = Self.newSearchUIDs(search.lines, afterUID: afterUID)
            DiagnosticLog.shared.record(
                "imap: subject \"\(filter)\" → \(uids.count) new uid(s) (after uid \(afterUID))",
                category: "mail")
            matchedUIDs.formUnion(uids)
        }

        var messages: [IncomingMessage] = []
        var highestUID = afterUID
        for uid in matchedUIDs.sorted() {
            // Fetch the FULL raw message (capped) and parse it ourselves.
            // `BODY[TEXT]` of the top level can be a tiny forwarding stub while
            // the real multipart content sits below — the whole message + our
            // own MIME walk handles forwards, nesting, and base64/QP parts.
            let fetch = try await run("UID FETCH \(uid) (UID BODY.PEEK[]<0.\(Self.maxFetchBytes)>)", step: "fetch")
            highestUID = max(highestUID, uid)
            guard let raw = fetch.literals.first else {
                DiagnosticLog.shared.record(
                    "imap: uid \(uid) fetch returned no body; skipping", category: "mail")
                continue
            }
            let rawString = String(decoding: raw, as: UTF8.self)
            let (headerText, body) = Self.splitMessage(rawString)
            let headers = Self.parseHeaders(headerText)
            let urls = Self.extractURLs(from: body)
            DiagnosticLog.shared.record(
                "imap: uid \(uid) from=\(headers["from"] ?? "?") subj=\"\(headers["subject"] ?? "")\" type=\(headers["content-type"]?.prefix(60) ?? "?") rawLen=\(rawString.count) bodyLen=\(body.count) urls=\(urls.count)",
                category: "mail")
            messages.append(IncomingMessage(
                uid: uid,
                from: headers["from"] ?? "",
                subject: headers["subject"] ?? "",
                date: headers["date"] ?? "",
                contentType: headers["content-type"] ?? "",
                transferEncoding: headers["content-transfer-encoding"] ?? "",
                body: body,
                urls: urls))
            // Courtesy: mark read so it doesn't show unread in Gmail. Dedup
            // relies on UID, not this.
            _ = try? await run("UID STORE \(uid) +FLAGS (\\Seen)", step: "store")
        }
        _ = try? await run("LOGOUT", step: "logout")
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
    public static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Trailing `{123}` literal byte count at the end of a line, if present.
    public static func trailingLiteralCount(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        let digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        return Int(digits)
    }

    /// Extracts a `[KEY value]` integer from SELECT response lines.
    public static func parseBracketValue(_ key: String, in lines: [String]) -> Int? {
        for line in lines {
            guard let range = line.range(of: "[\(key) ") else { continue }
            let rest = line[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            if let value = Int(digits) { return value }
        }
        return nil
    }

    /// UIDs from an untagged `* SEARCH 1 2 3` line.
    public static func parseSearchUIDs(_ lines: [String]) -> [Int] {
        for line in lines {
            let upper = line.uppercased()
            guard upper.hasPrefix("* SEARCH") else { continue }
            return line.split(separator: " ").compactMap { Int($0) }
        }
        return []
    }

    /// New UIDs from a `* SEARCH` response, keeping only those strictly greater
    /// than `afterUID`. IMAP `UID SEARCH UID N:*` returns the highest existing
    /// UID even when it's below N — the range `N:*` is order-independent and `*`
    /// is the last message — so without this filter the newest message would
    /// re-import on every poll.
    public static func newSearchUIDs(_ lines: [String], afterUID: Int) -> [Int] {
        parseSearchUIDs(lines).filter { $0 > afterUID }
    }

    /// Splits a raw RFC822 message into its top-level header block and body at
    /// the first blank line (CRLFCRLF, or LFLF as a fallback).
    public static func splitMessage(_ raw: String) -> (headers: String, body: String) {
        if let range = raw.range(of: "\r\n\r\n") {
            return (String(raw[..<range.lowerBound]), String(raw[range.upperBound...]))
        }
        if let range = raw.range(of: "\n\n") {
            return (String(raw[..<range.lowerBound]), String(raw[range.upperBound...]))
        }
        return (raw, "")
    }

    /// Parses `Key: value` headers (lowercased keys; unfolds simple folds).
    public static func parseHeaders(_ raw: String) -> [String: String] {
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
    /// `href` targets in HTML. Gmail bodies are usually quoted-printable, where
    /// soft line breaks (`=\r\n`) split long URLs and `=XX` escapes hide chars;
    /// when we detect QP we decode the whole body first (in a true QP body any
    /// literal `=` is itself encoded, so a full decode is safe).
    public static func extractURLs(from body: String) -> [URL] {
        let text = (body.contains("=\r\n") || body.contains("=\n") || body.contains("=3D"))
            ? decodeQuotedPrintable(body) : body

        var found: [URL] = []
        var seen = Set<String>()
        func add(_ string: String) {
            let candidate = string.trimmingCharacters(
                in: CharacterSet(charactersIn: "\"'<>) \t\r\n"))
            guard let url = URL(string: candidate), url.scheme?.hasPrefix("http") == true,
                  seen.insert(url.absoluteString).inserted else { return }
            found.append(url)
        }
        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url { add(url.absoluteString) }
            }
        }
        // hrefs (links the detector may miss).
        var searchRange = text.startIndex..<text.endIndex
        while let hrefRange = text.range(of: "href=", options: .caseInsensitive, range: searchRange) {
            let after = text[hrefRange.upperBound...]
            let quote = after.first
            let valueStart = (quote == "\"" || quote == "'")
                ? after.index(after: after.startIndex) : after.startIndex
            let terminators: Set<Character> = quote == "\"" ? ["\""]
                : quote == "'" ? ["'"] : [" ", ">", "\r", "\n"]
            let end = text[valueStart...].firstIndex { terminators.contains($0) } ?? text.endIndex
            add(String(text[valueStart..<end]))
            searchRange = end..<text.endIndex
        }
        return found
    }

    /// Decodes a quoted-printable string: drops soft line breaks and turns `=XX`
    /// hex escapes back into bytes (decoded as UTF-8). Iterates Unicode scalars,
    /// not Characters — Swift clusters `\r\n` into one Character, which would
    /// hide the soft break.
    public static func decodeQuotedPrintable(_ s: String) -> String {
        var bytes: [UInt8] = []
        let scalars = Array(s.unicodeScalars)
        let cr = Unicode.Scalar(13), lf = Unicode.Scalar(10), eq = Unicode.Scalar(61)
        var i = 0
        func hex(_ scalar: Unicode.Scalar) -> UInt8? { UInt8(String(scalar), radix: 16) }
        while i < scalars.count {
            if scalars[i] == eq {
                if i + 1 < scalars.count, scalars[i + 1] == lf { i += 2; continue }
                if i + 2 < scalars.count, scalars[i + 1] == cr, scalars[i + 2] == lf { i += 3; continue }
                if i + 2 < scalars.count, let hi = hex(scalars[i + 1]), let lo = hex(scalars[i + 2]) {
                    bytes.append(hi << 4 | lo); i += 3; continue
                }
            }
            bytes.append(contentsOf: Array(String(scalars[i]).utf8))
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
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
                case .cancelled:
                    result = .failure(IMAPError(step: "connect", detail: "cancelled"))
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
