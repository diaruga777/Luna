//
//  CredentialKeychain.swift
//  LunaStorage
//

import Foundation
import os
import Security

/// Shared keychain primitive for user-restorable Luna credentials.
///
/// These secrets are user-created app credentials/tokens rather than
/// device-bound keys. Use a migratable class so encrypted device backups can
/// restore them, and mark them synchronizable so iCloud Keychain can carry them
/// between the user's trusted devices when enabled.
public enum CredentialKeychain {
    private static let logger = Logger(subsystem: "luna", category: "keychain")

    public static let accessibleClass = kSecAttrAccessibleAfterFirstUnlock

    public static func read(service: String, account: String) -> String? {
        guard let data = readData(service: service, account: account) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func readData(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account, synchronizable: kSecAttrSynchronizableAny)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return data
    }

    public static func write(_ value: String?, service: String, account: String) {
        write(value.map { Data($0.utf8) }, service: service, account: account)
    }

    public static func write(_ value: Data?, service: String, account: String) {
        delete(service: service, account: account)
        guard let value, !value.isEmpty else { return }

        var insert = baseQuery(service: service, account: account, synchronizable: true)
        insert[kSecValueData as String] = value
        insert[kSecAttrAccessible as String] = accessibleClass
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("SecItemAdd failed (\(status)) for \(account, privacy: .public)")
        }
    }

    public static func delete(service: String, account: String) {
        SecItemDelete(baseQuery(
            service: service, account: account, synchronizable: kSecAttrSynchronizableAny
        ) as CFDictionary)
    }

    public static func baseQuery(
        service: String, account: String, synchronizable: Any? = nil
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let synchronizable {
            query[kSecAttrSynchronizable as String] = synchronizable
        }
        return query
    }
}
