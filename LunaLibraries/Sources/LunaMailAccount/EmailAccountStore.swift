//
//  EmailAccountStore.swift
//  LunaMailAccount
//

import Foundation
import LunaAppConfig
import LunaStorage

/// The stored secret for an account: an app-specific password, or OAuth tokens.
public enum MailCredential: Equatable {
    case appPassword(String)
    case oauth(OAuthTokens)
}

/// Persistence for the connected `EmailAccount`.
///
/// Account **metadata** (provider, address, display name, resolved servers)
/// goes in App-Group `UserDefaults` so all three apps and the extensions see
/// the same account. The **secret** goes in the Keychain, keyed by kind.
///
/// The Keychain items live in the shared App-Group access group (see
/// `CredentialKeychain`) so all three apps read one credential — that's what
/// lets a second Luna app's onboarding collapse to the "Email already
/// connected" step instead of asking the user to sign in again. The secrets
/// are migratable and iCloud-Keychain synchronizable so device
/// transfer/restore can preserve the connected account.
public final class EmailAccountStore {

    public static let shared = EmailAccountStore()

    private let accountKey = "lunaEmailAccount"
    private let defaults: UserDefaults
    private let credentialStorage: MailCredentialStorage
    private let service = "com.hsanabria.luna.mailaccount"
    private let appPasswordAccount = "app-password"
    private let oauthAccount = "oauth-tokens"

    /// Posted whenever the account is saved or cleared.
    public static let accountChanged = Notification.Name("LunaEmailAccountChanged")

    /// `credentialStorage` defaults to the real Keychain; injectable so tests and
    /// the onboarding replay overlay can redirect the secret to an in-memory
    /// stand-in without changing any of the logic below.
    public init(defaults: UserDefaults? = nil, credentialStorage: MailCredentialStorage = KeychainCredentialStorage()) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppConfig.appGroupID)
            ?? .standard
        self.credentialStorage = credentialStorage
    }

    // MARK: - Account metadata

    public var account: EmailAccount? {
        guard let data = defaults.data(forKey: accountKey) else { return nil }
        return try? JSONDecoder().decode(EmailAccount.self, from: data)
    }

    /// True when an account is connected and has a usable credential.
    public var isConfigured: Bool {
        account != nil && credential != nil
    }

    // MARK: - Save / clear

    /// Persists the account and its credential atomically (from the caller's
    /// point of view), then posts `accountChanged`.
    public func save(_ account: EmailAccount, credential: MailCredential) {
        if let data = try? JSONEncoder().encode(account) {
            defaults.set(data, forKey: accountKey)
        }
        setCredential(credential)
        NotificationCenter.default.post(name: Self.accountChanged, object: nil)
    }

    /// Updates only the OAuth tokens (after a refresh) without touching metadata.
    public func updateOAuthTokens(_ tokens: OAuthTokens) {
        setCredential(.oauth(tokens))
    }

    /// Removes the account and its credential, then posts `accountChanged`.
    public func clear() {
        defaults.removeObject(forKey: accountKey)
        credentialStorage.delete(service: service, account: appPasswordAccount)
        credentialStorage.delete(service: service, account: oauthAccount)
        NotificationCenter.default.post(name: Self.accountChanged, object: nil)
    }

    // MARK: - Credential (Keychain, or an injected stand-in)

    public var credential: MailCredential? {
        if let password = credentialStorage.read(service: service, account: appPasswordAccount),
           !password.isEmpty {
            return .appPassword(password)
        }
        if let json = credentialStorage.read(service: service, account: oauthAccount),
           let data = json.data(using: .utf8),
           let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) {
            return .oauth(tokens)
        }
        return nil
    }

    private func setCredential(_ credential: MailCredential) {
        switch credential {
        case .appPassword(let password):
            credentialStorage.write(password, service: service, account: appPasswordAccount)
            credentialStorage.delete(service: service, account: oauthAccount)
        case .oauth(let tokens):
            if let data = try? JSONEncoder().encode(tokens) {
                credentialStorage.write(
                    String(decoding: data, as: UTF8.self), service: service, account: oauthAccount)
            }
            credentialStorage.delete(service: service, account: appPasswordAccount)
        }
    }
}
