//
//  BooxSendSettings.swift
//  Clip
//

import Foundation

/// Send-to-Boox configuration, persisted in standard defaults. The auth token
/// (the one secret) lives in the Keychain via `SendCredentialsStoring`.
/// Mirrors `KindleSendSettings`.
enum BooxSendSettings {

    /// Onyx accounts are region-bound; the API host differs per region.
    enum Region: String, CaseIterable {
        case europe
        case unitedStates
        case global

        var displayName: String {
            switch self {
            case .europe: return "Europe"
            case .unitedStates: return "United States"
            case .global: return "Global / Other"
            }
        }

        /// API host for the region (path prefix `/api/1/`).
        var host: String {
            switch self {
            case .europe: return "eur.boox.com"
            case .unitedStates: return "send2boox.com"
            case .global: return "www.boox.com"
            }
        }
    }

    private static let modeKey = "booxSendMode"
    private static let identityKey = "booxAccountIdentity"
    private static let regionKey = "booxRegion"

    static var sendMode: ArticleSendMode {
        get { ArticleSendMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// The email/phone the auth token belongs to (display + re-login).
    static var accountIdentity: String {
        get { UserDefaults.standard.string(forKey: identityKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: identityKey) }
    }

    static var region: Region {
        get { Region(rawValue: UserDefaults.standard.string(forKey: regionKey) ?? "") ?? .europe }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: regionKey) }
    }

    static var host: String { region.host }

    /// True when a token is present (the only thing needed to send).
    static func isConfigured(credentials: SendCredentialsStoring) -> Bool {
        !(credentials.booxToken() ?? "").isEmpty
    }
}
