//
//  CredentialKeychain.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig
import os
import Security

/// Shared keychain primitive for user-restorable Luna credentials.
///
/// These secrets are user-created app credentials and tokens rather than
/// device-bound keys. Items store under a migratable class, so encrypted
/// device backups can restore them, and mark themselves synchronizable, so
/// iCloud Keychain can carry them between the user's trusted devices when
/// enabled.
///
/// Items live in the shared App-Group keychain access group (on iOS the
/// app-group entitlement doubles as a keychain access group), so a
/// credential saved in one Luna app is readable by the other apps in the
/// suite. That is what lets a second app's onboarding skip the email
/// sign-in. An item written before this sharing existed sits in that app's
/// private access group instead; `readData` migrates it into the shared
/// group when it is the only copy found.
public enum CredentialKeychain {
    private static let logger = Logger(subsystem: LunaLogging.subsystem, category: "keychain")

    public static let accessibleClass = kSecAttrAccessibleAfterFirstUnlock

    /// The keychain access group every Luna credential is stored in — the
    /// shared App Group, so all apps in the suite see one set of credentials.
    public static var sharedAccessGroup: String { AppConfig.appGroupID }

    public static func read(service: String, account: String) -> String? {
        guard let data = readData(service: service, account: account) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func readData(service: String, account: String) -> Data? {
        if let data = copyData(service: service, account: account, accessGroup: sharedAccessGroup) {
            return data
        }
        return migrateLegacyItem(service: service, account: account)
    }

    public static func write(_ value: String?, service: String, account: String) {
        write(value.map { Data($0.utf8) }, service: service, account: account)
    }

    public static func write(_ value: Data?, service: String, account: String) {
        delete(service: service, account: account)
        guard let value, !value.isEmpty else { return }

        var insert = baseQuery(service: service, account: account, synchronizable: true)
        insert[kSecAttrAccessGroup as String] = sharedAccessGroup
        insert[kSecValueData as String] = value
        insert[kSecAttrAccessible as String] = accessibleClass
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("SecItemAdd failed (\(status)) for \(account, privacy: .public)")
        }
    }

    /// Deletes every copy of the item this process can reach: the
    /// shared-group item and any legacy private-group leftover (no
    /// access-group filter means all accessible groups). This keeps a
    /// cleared credential from resurrecting later through the
    /// legacy-migration read path.
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

    // MARK: - Internals

    private static func copyData(
        service: String, account: String, accessGroup: String?
    ) -> Data? {
        var query = baseQuery(
            service: service, account: account, synchronizable: kSecAttrSynchronizableAny)
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return data
    }

    /// Pre-suite builds wrote the item into this app's own private access
    /// group, invisible to the other Luna apps. Called only after a
    /// shared-group miss: an unscoped search covers every group this
    /// process can reach, so any hit here is a legacy item. Rewrite it into
    /// the shared group (`write` first deletes all reachable copies) and
    /// return it.
    private static func migrateLegacyItem(service: String, account: String) -> Data? {
        guard let data = copyData(service: service, account: account, accessGroup: nil)
        else { return nil }
        write(data, service: service, account: account)
        logger.info("Migrated \(account, privacy: .public) into the shared access group")
        return data
    }
}
