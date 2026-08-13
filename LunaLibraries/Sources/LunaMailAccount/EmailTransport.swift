//
//  EmailTransport.swift
//  LunaMailAccount
//

import Foundation

/// A provider response that definitively means the saved login must be renewed.
///
/// Network timeouts, DNS failures, server outages, and ordinary API failures
/// must keep their original errors so they never put the account into recovery.
public struct EmailAuthenticationError: Error, CustomStringConvertible {
    public let issue: EmailAuthenticationIssue
    public let detail: String

    public init(issue: EmailAuthenticationIssue, detail: String) {
        self.issue = issue
        self.detail = detail
    }

    public var description: String {
        "Email authentication failed (\(issue.rawValue)): \(detail)"
    }
}

/// A composed, ready-to-send message. `rawMIME` is the full RFC 5322 message
/// (headers + body); both backends consume it — SMTP writes it in `DATA`, and
/// Graph sends it base64-encoded via `/me/sendMail`.
public struct OutgoingEmail: Equatable {
    public let recipients: [String]
    public let subject: String
    public let rawMIME: Data

    public init(recipients: [String], subject: String, rawMIME: Data) {
        self.recipients = recipients
        self.subject = subject
        self.rawMIME = rawMIME
    }
}

/// One message discovered while scanning for Luna shares (or matched newsletter
/// filters). `id` is the provider-native handle used to mark it read (IMAP UID
/// string / Graph message id); `uid` is the numeric IMAP UID for the dedupe
/// cursor (nil for Graph, which uses `receivedDateTime` ordering instead).
public struct FetchedMessage: Equatable {
    public let id: String
    public let uid: Int?
    public let from: String
    public let subject: String
    public let date: String
    /// Lowercased header keys → values (unfolded).
    public let headers: [String: String]
    public let bodyText: String
    /// Parsed Luna marker, if this is a Luna share.
    public let marker: LunaShareMarker?

    public init(id: String, uid: Int?, from: String, subject: String, date: String,
                headers: [String: String], bodyText: String, marker: LunaShareMarker?) {
        self.id = id
        self.uid = uid
        self.from = from
        self.subject = subject
        self.date = date
        self.headers = headers
        self.bodyText = bodyText
        self.marker = marker
    }
}

/// Opaque dedupe cursor persisted between fetches. The enum holds exactly one
/// provider's cursor shape at a time — an IMAP uid+uidValidity pair, a Graph
/// token, or `.fresh` for "no cursor yet" — so a caller can never mix an IMAP
/// value with a Graph token or lose the "not fetched" state to a stray nil.
public enum MailCursor: Codable, Equatable {
    case fresh
    /// IMAP's uid+uidValidity high-water mark (the cursor resets when validity
    /// changes — the mailbox renumbered its UIDs).
    case imap(uid: Int, uidValidity: Int)
    /// Graph's ISO `receivedDateTime` high-water mark.
    case graph(token: String)

    /// The token a `.graph` cursor carries, or empty for any other case —
    /// `GraphMailTransport` only ever wants "the token, or none yet".
    public var graphToken: String {
        if case .graph(let token) = self { return token }
        return ""
    }
}

/// The result of a Luna-share scan: the matched messages and the cursor to
/// persist for the next run.
public struct FetchResult: Equatable {
    public let messages: [FetchedMessage]
    public let cursor: MailCursor
    public init(messages: [FetchedMessage], cursor: MailCursor) {
        self.messages = messages
        self.cursor = cursor
    }
}

/// Outcome of attempting to install the "mark Luna mail read / skip inbox" filter.
public enum FilterOutcome: Equatable {
    /// Filter created programmatically.
    case created
    /// Provider has no filter API — the caller should show guided setup.
    case guidedRequired
    /// Attempt failed (e.g. missing scope); caller falls back to guided setup.
    case failed(String)
}

/// Provider-agnostic mail operations Luna needs. Backed by `IMAPSMTPTransport`
/// (app-password providers) or `GraphMailTransport` (Outlook).
public protocol EmailTransport: Sendable {
    /// Proves the credential works (login + a cheap no-op). Throws on failure.
    func verifyCredentials() async throws

    /// Sends one message on the user's behalf.
    func send(_ email: OutgoingEmail) async throws

    /// Returns Luna-share messages received since `cursor` (also matched
    /// newsletter senders/subjects when `extraSenders`/`extraSubjects` are set),
    /// plus the cursor to persist next. Pass `.fresh` for a first run.
    func fetchShares(
        after cursor: MailCursor,
        extraSenders: [String],
        extraSubjects: [String]
    ) async throws -> FetchResult

    /// Marks the given messages read (best-effort; failures are non-fatal).
    func markRead(_ messageIDs: [String]) async throws

    /// Installs the Luna inbox filter if the provider supports it.
    func createLunaFilter() async throws -> FilterOutcome
}
