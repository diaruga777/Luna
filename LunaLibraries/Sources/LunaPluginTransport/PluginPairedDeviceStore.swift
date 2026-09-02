//
//  PluginPairedDeviceStore.swift
//  LunaPluginTransport
//

import Foundation
import LunaPluginKit

/// Where a plugin's paired peripherals live.
///
/// The bridge owns the row rather than the plugin: a `pairedDevice` settings
/// row has to show a name before any hook has run, and a plugin that lost its
/// own bookkeeping would strand a bonded reader. It is the plugin's own
/// `luna.storage` space under a reserved key, so deleting the plugin takes the
/// pairing with it.
public final class PluginPairedDeviceStore: @unchecked Sendable {

    /// Reserved: a manifest cannot declare a key starting with `_`, so this can
    /// never collide with something the plugin wrote.
    public static let storageKey = "_pairedDevices"

    private let store: PluginKVStore

    public init(store: PluginKVStore = .shared) {
        self.store = store
    }

    public func devices(pluginID: String) -> [PluginBluetoothDevice] {
        guard let json = store.valueJSON(pluginID: pluginID, key: Self.storageKey),
              let devices = try? JSONDecoder().decode(
                [PluginBluetoothDevice].self, from: Data(json.utf8))
        else { return [] }
        return devices
    }

    /// Adds or replaces `device` by id, and mirrors its name into the
    /// manifest's `pairedDevice` field so Settings shows it.
    public func add(_ device: PluginBluetoothDevice, pluginID: String, settingKey: String?) {
        var devices = self.devices(pluginID: pluginID).filter { $0.id != device.id }
        devices.append(device)
        write(devices, pluginID: pluginID)
        guard let settingKey else { return }
        let label = device.name ?? device.id
        try? PluginPlatformServices.settings?.setValueJSON(
            PluginPairedDeviceStore.jsonString(label), pluginID: pluginID, key: settingKey)
    }

    public func remove(deviceID: String, pluginID: String, settingKey: String?) {
        let devices = self.devices(pluginID: pluginID).filter { $0.id != deviceID }
        write(devices, pluginID: pluginID)
        guard let settingKey, devices.isEmpty else { return }
        try? PluginPlatformServices.settings?.setValueJSON(
            nil, pluginID: pluginID, key: settingKey)
    }

    private func write(_ devices: [PluginBluetoothDevice], pluginID: String) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        _ = store.setValueJSON(
            String(decoding: data, as: UTF8.self), pluginID: pluginID,
            key: Self.storageKey, now: Date())
    }

    /// A JSON string literal, for a settings value the renderer reads as text.
    static func jsonString(_ text: String) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: text, options: [.fragmentsAllowed])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}
