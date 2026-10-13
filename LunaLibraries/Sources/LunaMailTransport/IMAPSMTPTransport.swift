//
//  IMAPSMTPTransport.swift
//  LunaMailTransport
//

import Foundation
import LunaMailAccount

/// `EmailTransport` for app-password providers (Gmail, iCloud, Yahoo, custom
/// IMAP) over IMAP + SMTP. Programmatic filters aren't available on this path
/// (Gmail's filter API is a separate OAuth flow handled by the login layer), so
/// `createLunaFilter()` reports `.guidedRequired`.
public struct IMAPSMTPTransport: EmailTransport {

    private let account: EmailAccount
    private let password: String
    private let server: MailServerConfig

    public struct ConfigurationError: Error, CustomStringConvertible {
        public let detail: String
        public var description: String { detail }
    }

    /// Fails if the account lacks resolved server settings (only OAuth/Outlook
    /// accounts legitimately have none — those use `GraphMailTransport`).
    public init(account: EmailAccount, password: String) throws {
        guard let server = account.server else {
            throw ConfigurationError(detail: "account has no IMAP/SMTP server settings")
        }
        self.account = account
        self.password = password
        self.server = server
    }

    private var imap: StreamIMAPClient {
        StreamIMAPClient(host: server.imapHost, port: server.imapPort)
    }
    private var smtp: StreamSMTPClient {
        StreamSMTPClient(host: server.smtpHost, port: server.smtpPort,
                         usesSTARTTLS: server.smtpUsesSTARTTLS)
    }
    private var imapUsername: String { account.provider.imapUsername(for: account.address) }
    private var smtpUsername: String { account.provider.smtpUsername(for: account.address) }

    // MARK: - EmailTransport

    public func verifyCredentials() async throws {
        try await imap.login(username: imapUsername, password: password)
        try await smtp.run(username: smtpUsername, password: password)
    }

    public func send(_ email: OutgoingEmail) async throws {
        try await smtp.run(
            username: smtpUsername, password: password,
            from: account.address, recipients: email.recipients, rawMessage: email.rawMIME)
    }

    public func fetchShares(
        after cursor: MailCursor, extraSenders: [String], extraSubjects: [String]
    ) async throws -> FetchResult {
        try await imap.fetchShares(
            username: imapUsername, password: password,
            after: cursor, senders: extraSenders, subjects: extraSubjects)
    }

    public func fetchRecentShares(
        since: Date, extraSenders: [String], extraSubjects: [String]
    ) async throws -> FetchResult {
        try await imap.fetchShares(
            username: imapUsername, password: password, after: .fresh,
            senders: extraSenders, subjects: extraSubjects, since: since)
    }

    public func markRead(_ messageIDs: [String]) async throws {
        let uids = messageIDs.compactMap(Int.init)
        try await imap.markSeen(username: imapUsername, password: password, uids: uids)
    }

    public func createLunaFilter() async throws -> FilterOutcome {
        .guidedRequired
    }
}
