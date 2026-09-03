//
//  PluginSecretsStore.swift
//  LunaPluginKit
//

import Foundation
import LunaStorage

/// `luna.secrets`: one Keychain item per (plugin, key).
///
/// It uses `CredentialKeychain`, so a plugin's secret lands in the shared
/// App-Group access group with the same accessibility every other Luna
/// credential has — the share and action extensions can READ what the app
/// wrote, which is what an export plugin needs when it runs in an extension.
public final class PluginSecretsStore: @unchecked Sendable {

    public static let shared = PluginSecretsStore()

    /// The Keychain service one plugin's items share. The plugin id is in the
    /// service rather than the account, so deleting a plugin's secrets is one
    /// prefix.
    public static func service(pluginID: String) -> String {
        "com.hsanabria.luna.plugin-secrets.\(pluginID)"
    }

    public init() {}

    public func secret(pluginID: String, key: String) -> String? {
        CredentialKeychain.read(service: Self.service(pluginID: pluginID), account: key)
    }

    public func setSecret(_ value: String?, pluginID: String, key: String) {
        CredentialKeychain.write(
            value, service: Self.service(pluginID: pluginID), account: key)
    }

    public func removeSecret(pluginID: String, key: String) {
        CredentialKeychain.delete(service: Self.service(pluginID: pluginID), account: key)
    }

    /// Removes every secret belonging to a plugin, including accounts the
    /// plugin created before an update changed its settings schema.
    public func removeAll(pluginID: String) {
        CredentialKeychain.deleteAll(service: Self.service(pluginID: pluginID))
    }
}
