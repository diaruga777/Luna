//
//  KindleSendSettings.swift
//  Clip
//

import Foundation

/// Send-to-Kindle configuration, persisted in standard defaults (the password
/// lives in the Keychain via `SendCredentialsStoring`).
enum KindleSendSettings {

    /// When articles are sent automatically.
    enum SendMode: String, CaseIterable {
        /// Never send automatically (long-press send still works).
        case off
        /// Every saved article is sent once it's ingested.
        case allSaves
        /// Pressing save twice within a few seconds sends that article.
        case doubleSave

        var displayName: String {
            switch self {
            case .off: return "Off"
            case .allSaves: return "All Saved Articles"
            case .doubleSave: return "Double Save"
            }
        }
    }

    /// SMTP presets; custom exposes the host field.
    enum Provider: String, CaseIterable {
        case gmail
        case custom

        var displayName: String {
            switch self {
            case .gmail: return "Gmail"
            case .custom: return "Custom"
            }
        }
    }

    private static let modeKey = "kindleSendMode"
    private static let kindleAddressKey = "kindleAddress"
    private static let providerKey = "kindleSMTPProvider"
    private static let hostKey = "kindleSMTPHost"
    private static let usernameKey = "kindleSMTPUsername"

    static let gmailHost = "smtp.gmail.com"
    /// Implicit-TLS submission port — the only mode the embedded client speaks.
    static let port: UInt16 = 465

    static var sendMode: SendMode {
        get {
            SendMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .off
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// The user's @kindle.com inbox address.
    static var kindleAddress: String {
        get { UserDefaults.standard.string(forKey: kindleAddressKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: kindleAddressKey) }
    }

    static var provider: Provider {
        get {
            Provider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .gmail
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    /// SMTP host actually used: the Gmail preset, or the custom host field.
    static var smtpHost: String {
        provider == .gmail ? gmailHost : customHost
    }

    static var customHost: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }

    /// Full email address used both to authenticate and as the From address —
    /// the one the user must put on Amazon's approved-sender list.
    static var smtpUsername: String {
        get { UserDefaults.standard.string(forKey: usernameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: usernameKey) }
    }

    /// True when everything needed to actually send is present.
    static func isConfigured(credentials: SendCredentialsStoring) -> Bool {
        !kindleAddress.isEmpty
            && !smtpHost.isEmpty
            && !smtpUsername.isEmpty
            && !(credentials.smtpPassword() ?? "").isEmpty
    }
}
