//
//  MailTransportFactory.swift
//  LunaMailTransport
//

import Foundation
import LunaMailAccount

/// Builds the right `EmailTransport` for the connected account: the app-password
/// IMAP/SMTP backend for Gmail/iCloud/Yahoo/custom, or the Graph backend for
/// Outlook. Returns nil when no account is configured.
public enum MailTransportFactory {

    public static func make(store: EmailAccountStore = .shared) -> EmailTransport? {
        guard store.isReady,
              let account = store.account,
              let credential = store.credential
        else { return nil }
        let transport: EmailTransport
        switch credential {
        case .appPassword(let password):
            guard let resolved = try? IMAPSMTPTransport(account: account, password: password)
            else { return nil }
            transport = resolved
        case .oauth:
            transport = GraphMailTransport(store: store)
        }
        return AuthenticationStateTrackingTransport(base: transport, store: store)
    }
}

/// Persists only typed authentication failures emitted by a concrete transport.
/// A later successful authenticated operation clears a stale issue automatically.
public struct AuthenticationStateTrackingTransport: EmailTransport {
    private let base: EmailTransport
    private let store: EmailAccountStore

    public init(base: EmailTransport, store: EmailAccountStore = .shared) {
        self.base = base
        self.store = store
    }

    public func verifyCredentials() async throws {
        try await perform { try await base.verifyCredentials() }
    }

    public func send(_ email: OutgoingEmail) async throws {
        try await perform { try await base.send(email) }
    }

    public func fetchShares(
        after cursor: MailCursor,
        extraSenders: [String],
        extraSubjects: [String]
    ) async throws -> FetchResult {
        try await perform {
            try await base.fetchShares(
                after: cursor, extraSenders: extraSenders, extraSubjects: extraSubjects)
        }
    }

    public func markRead(_ messageIDs: [String]) async throws {
        try await perform { try await base.markRead(messageIDs) }
    }

    public func createLunaFilter() async throws -> FilterOutcome {
        try await perform { try await base.createLunaFilter() }
    }

    private func perform<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            let result = try await operation()
            store.clearAuthenticationIssue()
            return result
        } catch let error as EmailAuthenticationError {
            store.markAuthenticationIssue(error.issue)
            throw error
        }
    }
}
