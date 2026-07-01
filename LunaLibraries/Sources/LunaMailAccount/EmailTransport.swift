//
//  EmailTransport.swift
//  LunaMailAccount
//

import Foundation

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

/// Opaque dedupe cursor persisted between fetches. IMAP uses `uid`+`uidValidity`
/// (reset the cursor when validity changes); Graph uses an ISO `receivedDateTime`
/// high-water mark in `token`.
public struct MailCursor: Codable, Equatable {
    public var uid: Int
    public var uidValidity: Int
    public var token: String?

    public init(uid: Int = 0, uidValidity: Int = 0, token: String? = nil) {
        self.uid = uid
        self.uidValidity = uidValidity
        self.token = token
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
    /// plus the cursor to persist next.
    func fetchShares(
        after cursor: MailCursor?,
        extraSenders: [String],
        extraSubjects: [String]
    ) async throws -> FetchResult

    /// Marks the given messages read (best-effort; failures are non-fatal).
    func markRead(_ messageIDs: [String]) async throws

    /// Installs the Luna inbox filter if the provider supports it.
    func createLunaFilter() async throws -> FilterOutcome
}
