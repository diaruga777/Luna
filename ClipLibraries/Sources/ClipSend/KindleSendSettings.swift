//
//  KindleSendSettings.swift
//  Clip
//

import Foundation

/// Send-to-Kindle configuration, persisted in standard defaults (the password
/// lives in the Keychain via `SendCredentialsStoring`).
public enum KindleSendSettings {

    /// Send timing is the shared `ArticleSendMode`.
    public typealias SendMode = ArticleSendMode

    /// SMTP presets; custom exposes the host field.
    public enum Provider: String, CaseIterable {
        case gmail
        case custom

        public var displayName: String {
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

    /// The "Also Send to Kindle" toggle. Shared with the mail importer
    /// (`IncomingMailSettings.autoSendToKindle` reads/writes the same key), so the
    /// send layer can consult it without depending on the mail layer.
    public static var autoSendToKindle: Bool {
        get { UserDefaults.standard.bool(forKey: "incomingMailAutoSendToKindle") }
        set { UserDefaults.standard.set(newValue, forKey: "incomingMailAutoSendToKindle") }
    }

    public static let gmailHost = "smtp.gmail.com"
    /// Implicit-TLS submission port — the only mode the embedded client speaks.
    public static let port: UInt16 = 465

    public static var sendMode: SendMode {
        get {
            SendMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .off
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// The user's @kindle.com inbox address.
    public static var kindleAddress: String {
        get { UserDefaults.standard.string(forKey: kindleAddressKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: kindleAddressKey) }
    }

    public static var provider: Provider {
        get {
            Provider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .gmail
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    /// SMTP host actually used: the Gmail preset, or the custom host field.
    public static var smtpHost: String {
        provider == .gmail ? gmailHost : customHost
    }

    public static var customHost: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }

    /// Full email address used both to authenticate and as the From address —
    /// the one the user must put on Amazon's approved-sender list.
    public static var smtpUsername: String {
        get { UserDefaults.standard.string(forKey: usernameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: usernameKey) }
    }

    /// True when everything needed to actually send is present.
    public static func isConfigured(credentials: SendCredentialsStoring) -> Bool {
        !kindleAddress.isEmpty
            && !smtpHost.isEmpty
            && !smtpUsername.isEmpty
            && !(credentials.smtpPassword() ?? "").isEmpty
    }
}
