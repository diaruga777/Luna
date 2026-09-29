import Foundation

/// Schema-aware settings storage. Secret fields use the same bare Keychain key
/// as `luna.secrets.get(key)`; the ordinary database contains only a set marker.
public final class PluginSettingsStore: PluginSettingsStoring {
    private let values: PluginKVStore
    private let secrets: PluginSecretsStore
    private let fields: (String) -> [PluginSettingField]

    public init(
        values: PluginKVStore, secrets: PluginSecretsStore = .shared,
        fields: @escaping (String) -> [PluginSettingField]
    ) {
        self.values = values
        self.secrets = secrets
        self.fields = fields
    }

    public func valueJSON(pluginID: String, key: String) -> String? {
        guard isSecret(pluginID: pluginID, key: key) else {
            return values.valueJSON(pluginID: pluginID, key: key)
        }
        // Earlier versions saved secret settings as plaintext JSON. Move an
        // existing value before erasing it, and never return it to a caller.
        if let json = values.valueJSON(pluginID: pluginID, key: key),
           let data = json.data(using: .utf8),
           let legacy = try? JSONDecoder().decode(String.self, from: data),
           !legacy.isEmpty {
            if secrets.secret(pluginID: pluginID, key: key) == nil {
                secrets.setSecret(legacy, pluginID: pluginID, key: key)
            }
            if secrets.secret(pluginID: pluginID, key: key) != nil {
                try? values.setValueJSON("\"\"", pluginID: pluginID, key: key)
            }
        }
        return secrets.secret(pluginID: pluginID, key: key) == nil ? nil : "\"\""
    }

    public func setValueJSON(_ json: String?, pluginID: String, key: String) throws {
        guard isSecret(pluginID: pluginID, key: key) else {
            try values.setValueJSON(json, pluginID: pluginID, key: key)
            return
        }
        let secret: String?
        if let json, json != "null" {
            guard let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(String.self, from: data) else {
                throw PluginStoreError.fileSystem(detail: "A secret setting must be a string.")
            }
            secret = decoded.isEmpty ? nil : decoded
        } else {
            secret = nil
        }
        secrets.setSecret(secret, pluginID: pluginID, key: key)
        guard secrets.secret(pluginID: pluginID, key: key) == secret else {
            throw PluginStoreError.fileSystem(detail: "The secret could not be saved in Keychain.")
        }
        try values.setValueJSON(secret == nil ? nil : "\"\"", pluginID: pluginID, key: key)
    }

    public func allValuesJSON(pluginID: String) -> [String: String] {
        var result = values.allValuesJSON(pluginID: pluginID)
        for field in fields(pluginID) where field.isSecret {
            result[field.key] = valueJSON(pluginID: pluginID, key: field.key)
        }
        return result
    }

    public func isConfigured(pluginID: String, fields: [PluginSettingField]) -> Bool {
        for field in fields where field.isRequired {
            guard let json = valueJSON(pluginID: pluginID, key: field.key) else { return false }
            if field.isSecret { continue }
            if json.isEmpty || json == "null" || json == "\"\"" || json == "false" { return false }
        }
        return true
    }

    private func isSecret(pluginID: String, key: String) -> Bool {
        fields(pluginID).contains { $0.key == key && $0.isSecret }
    }
}
