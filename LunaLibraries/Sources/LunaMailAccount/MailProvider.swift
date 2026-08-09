//
//  MailProvider.swift
//  LunaMailAccount
//

import Foundation
import LunaModels

/// IMAP/SMTP connection settings for an app-password account. IMAP is always
/// implicit TLS on 993 for the providers we support; SMTP is either implicit
/// TLS (465) or STARTTLS (587, e.g. iCloud).
public struct MailServerConfig: Codable, Equatable {
    public var imapHost: String
    public var imapPort: Int
    public var smtpHost: String
    public var smtpPort: Int
    /// True → SMTP begins plaintext and upgrades via STARTTLS (port 587).
    /// False → implicit TLS from connect (port 465).
    public var smtpUsesSTARTTLS: Bool

    public init(imapHost: String, imapPort: Int = 993,
                smtpHost: String, smtpPort: Int, smtpUsesSTARTTLS: Bool) {
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUsesSTARTTLS = smtpUsesSTARTTLS
    }
}

/// A supported email provider and everything Luna needs to talk to it: the
/// server settings (for app-password providers), how to authenticate, how the
/// user obtains a credential, and whether filters can be automated.
public struct MailProvider: Equatable {

    public enum ID: String, Codable, CaseIterable, Equatable {
        case gmail
        case icloud
        case yahoo
        case outlook
        case generic
    }

    public let id: ID
    public let displayName: String
    /// Server settings for app-password providers; `nil` for OAuth providers
    /// (Outlook talks to Graph, not IMAP/SMTP) and for `.generic` until the
    /// user's servers are resolved (autodiscovery or manual entry).
    public let server: MailServerConfig?
    /// Where the user creates an app-specific password (nil for OAuth/generic).
    public let appPasswordURL: URL?
    /// Short guidance shown on the credential-entry screen.
    public let setupInstructions: String?
    /// Domain suffixes that map to this provider (for inference from an address).
    public let domains: [String]

    public init(id: ID, displayName: String, server: MailServerConfig?,
                appPasswordURL: URL?, setupInstructions: String?, domains: [String]) {
        self.id = id
        self.displayName = displayName
        self.server = server
        self.appPasswordURL = appPasswordURL
        self.setupInstructions = setupInstructions
        self.domains = domains
    }

    // MARK: - Username derivation

    /// The username to present at IMAP login for `address`. iCloud expects the
    /// short name (local part); everyone else uses the full address.
    public func imapUsername(for address: String) -> String {
        id == .icloud ? localPart(of: address) : address
    }

    /// The username to present at SMTP auth for `address`. Always the full
    /// address for the providers we support.
    public func smtpUsername(for address: String) -> String { address }

    private func localPart(of address: String) -> String {
        guard let at = address.firstIndex(of: "@") else { return address }
        return String(address[..<at])
    }

    // MARK: - Registry

    /// The provider for a known `ID`. `.generic` carries no server (resolved
    /// per-account); the concrete providers carry their fixed 2026 settings.
    public static func provider(for id: ID) -> MailProvider {
        switch id {
        case .gmail:
            return MailProvider(
                id: .gmail, displayName: L10n.string("MailAccount_mailProvider_gmailDisplayName"),
                server: MailServerConfig(
                    imapHost: "imap.gmail.com",
                    smtpHost: "smtp.gmail.com", smtpPort: 465, smtpUsesSTARTTLS: false),
                appPasswordURL: URL(string: "https://myaccount.google.com/apppasswords"),
                setupInstructions: L10n.string("MailAccount_mailProvider_gmailSetupInstructions"),
                domains: ["gmail.com", "googlemail.com"])
        case .icloud:
            return MailProvider(
                id: .icloud, displayName: L10n.string("MailAccount_mailProvider_icloudDisplayName"),
                server: MailServerConfig(
                    imapHost: "imap.mail.me.com",
                    smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpUsesSTARTTLS: true),
                appPasswordURL: URL(string: "https://appleid.apple.com"),
                setupInstructions: L10n.string("MailAccount_mailProvider_icloudSetupInstructions"),
                domains: ["icloud.com", "me.com", "mac.com"])
        case .yahoo:
            return MailProvider(
                id: .yahoo, displayName: L10n.string("MailAccount_mailProvider_yahooDisplayName"),
                server: MailServerConfig(
                    imapHost: "imap.mail.yahoo.com",
                    smtpHost: "smtp.mail.yahoo.com", smtpPort: 465, smtpUsesSTARTTLS: false),
                appPasswordURL: URL(string: "https://login.yahoo.com/account/security/app-passwords"),
                setupInstructions: L10n.string("MailAccount_mailProvider_yahooSetupInstructions"),
                domains: ["yahoo.com", "ymail.com", "rocketmail.com"])
        case .outlook:
            return MailProvider(
                id: .outlook, displayName: L10n.string("MailAccount_mailProvider_outlookDisplayName"),
                server: nil,
                appPasswordURL: nil,
                setupInstructions: nil,
                domains: ["outlook.com", "hotmail.com", "live.com", "msn.com"])
        case .generic:
            return MailProvider(
                id: .generic, displayName: L10n.string("MailAccount_mailProvider_genericDisplayName"),
                server: nil,
                appPasswordURL: nil,
                setupInstructions: L10n.string("MailAccount_mailProvider_genericSetupInstructions"),
                domains: [])
        }
    }
}
