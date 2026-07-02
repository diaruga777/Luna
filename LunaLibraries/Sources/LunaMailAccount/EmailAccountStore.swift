//
//  EmailAccountStore.swift
//  LunaMailAccount
//

import Foundation
import os
import Security
import LunaAppConfig

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
/// The account is created/used in the main app process, so the Keychain items
/// need no shared access group (matching `KeychainSendCredentialsStore`).
public final class EmailAccountStore {

    public static let shared = EmailAccountStore()

    private let accountKey = "lunaEmailAccount"
    private let defaults: UserDefaults
    private let service = "com.hsanabria.luna.mailaccount"
    private let appPasswordAccount = "app-password"
    private let oauthAccount = "oauth-tokens"

    /// Posted whenever the account is saved or cleared.
    public static let accountChanged = Notification.Name("LunaEmailAccountChanged")

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppConfig.appGroupID)
            ?? .standard
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
        writeSecret(nil, account: appPasswordAccount)
        writeSecret(nil, account: oauthAccount)
        NotificationCenter.default.post(name: Self.accountChanged, object: nil)
    }

    // MARK: - Credential (Keychain)

    public var credential: MailCredential? {
        if let password = readSecret(account: appPasswordAccount), !password.isEmpty {
            return .appPassword(password)
        }
        if let json = readSecret(account: oauthAccount),
           let data = json.data(using: .utf8),
           let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) {
            return .oauth(tokens)
        }
        return nil
    }

    private func setCredential(_ credential: MailCredential) {
        switch credential {
        case .appPassword(let password):
            writeSecret(password, account: appPasswordAccount)
            writeSecret(nil, account: oauthAccount)
        case .oauth(let tokens):
            if let data = try? JSONEncoder().encode(tokens) {
                writeSecret(String(decoding: data, as: UTF8.self), account: oauthAccount)
            }
            writeSecret(nil, account: appPasswordAccount)
        }
    }

    // MARK: - Keychain primitives

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readSecret(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func writeSecret(_ value: String?, account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess {
            // A silently dropped credential shows a "connected" account whose
            // every send fails as not-configured — leave a trace.
            Logger(subsystem: "luna", category: "keychain")
                .error("SecItemAdd failed (\(status)) for \(account, privacy: .public)")
        }
    }
}
