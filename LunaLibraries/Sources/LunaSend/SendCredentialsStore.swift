//
//  SendCredentialsStore.swift
//  Luna
//

import Foundation
import os
import Security

/// Holds the secret for the Boox send feature: the Send2Boox auth token.
/// (Kindle sends through the connected email account, so it needs no secret
/// here.)
public protocol SendCredentialsStoring {
    /// The stored Send2Boox auth token, if any.
    func booxToken() -> String?
    /// Stores (or, with nil/empty, deletes) the Send2Boox auth token.
    func setBooxToken(_ token: String?)
}

/// Keychain-backed credential storage. Sends always run in the main app
/// process, so no shared access group is needed.
public final class KeychainSendCredentialsStore: SendCredentialsStoring {

    public static let shared = KeychainSendCredentialsStore()

    private let booxService = "com.hsanabria.luna.boox"
    private let booxAccount = "boox-token"

    public func booxToken() -> String? { read(service: booxService, account: booxAccount) }
    public func setBooxToken(_ token: String?) {
        write(token, service: booxService, account: booxAccount)
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ value: String?, service: String, account: String) {
        let query = baseQuery(service: service, account: account)
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

/// In-memory stand-in for tests.
public final class InMemorySendCredentialsStore: SendCredentialsStoring {
    private var token: String?

    public init() {}

    public func booxToken() -> String? { token }
    public func setBooxToken(_ newToken: String?) {
        token = (newToken?.isEmpty ?? true) ? nil : newToken
    }
}
