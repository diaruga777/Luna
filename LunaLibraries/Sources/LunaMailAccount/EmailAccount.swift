//
//  EmailAccount.swift
//  LunaMailAccount
//

import Foundation

/// OAuth token bundle for an OAuth provider (Outlook). Stored in the Keychain.
public struct OAuthTokens: Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Absolute expiry of `accessToken`.
    public var expiry: Date

    public init(accessToken: String, refreshToken: String, expiry: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
    }

    /// True when the access token is expired (or within a 60s safety margin).
    public func isExpired(now: Date = Date()) -> Bool {
        expiry.timeIntervalSince(now) < 60
    }
}

/// The user's connected email account — the identity Luna sends from and reads
/// with. One account per install (shared across the three apps via the App
/// Group). Metadata is Codable and lives in App-Group defaults; the secret
/// (app password or OAuth tokens) lives in the Keychain, keyed separately.
public struct EmailAccount: Codable, Equatable {
    public var providerID: MailProvider.ID
    /// Full email address — the From address and (for app-password providers)
    /// the SMTP/IMAP account.
    public var address: String
    /// Optional display name used in the outgoing `From` header.
    public var displayName: String?
    /// Resolved IMAP/SMTP settings for app-password providers; `nil` for OAuth
    /// providers (Outlook, which uses Graph).
    public var server: MailServerConfig?

    public init(providerID: MailProvider.ID, address: String,
                displayName: String? = nil, server: MailServerConfig? = nil) {
        self.providerID = providerID
        self.address = address
        self.displayName = displayName
        self.server = server
    }

    /// The registry entry for this account's provider.
    public var provider: MailProvider { MailProvider.provider(for: providerID) }

    /// The `From` header value: `"Name" <addr>` when a display name is set.
    public var fromHeader: String {
        if let name = displayName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\"\(name)\" <\(address)>"
        }
        return address
    }
}
