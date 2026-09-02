//
//  PluginTransportComposition.swift
//  LunaPluginTransport
//

import Foundation
import LunaPluginKit
import LunaPluginRuntime
import LunaSend
import LunaStorage

/// The transport tier's one composition point
/// (`claudedocs/plans/plugin-platform.md` §10).
///
/// `bridges` goes into `PluginPlatformComposition.install(additionalBridges:)`
/// in central Luna's three roots; `install`, `appDidLaunch` and
/// `sceneDidForeground` are called from `KindWiring+Luna`, where the Swift
/// Xteink wiring used to be.
public enum PluginTransportComposition {

    /// The bundled Xteink plugin's id. The migration below is the only place
    /// the transport tier names a plugin: it moves what the Swift Xteink path
    /// stored into the plugin's own secrets and settings.
    public static let xteinkPluginID = "app.luna.xteink"

    private static let stateLock = NSLock()
    private static var centerStore: PluginBluetoothCenterStore?

    /// The `luna.bluetooth` and `luna.wifi` bridges for `processKind`.
    ///
    /// Both are handed over in every process: a declared capability stays
    /// visible, and outside the app every call rejects with `unavailable-here`
    /// so a plugin can branch on the code rather than on a missing namespace.
    public static func bridges(
        processKind: PluginProcessKind,
        scheduler: PluginCallbackScheduling,
        makers: (any PluginTransportMaking)? = nil,
        joiner: (any PluginWiFiJoining)? = nil,
        invoker: (any PluginHookInvoking)? = nil
    ) -> [any PluginCapabilityInstalling] {
        let store = PluginBluetoothCenterStore(
            makers: makers ?? SystemPluginTransportMaker(), invoker: invoker)
        stateLock.lock()
        centerStore = store
        stateLock.unlock()
        return [
            PluginBluetoothBridge(
                processKind: processKind, scheduler: scheduler, centers: store),
            PluginWiFiBridge(
                processKind: processKind, scheduler: scheduler,
                joiner: joiner ?? SystemPluginWiFiJoiner()),
        ]
    }

    /// The centers this process holds, for the lifecycle legs below.
    public static var centers: PluginBluetoothCenterStore? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return centerStore
    }

    // MARK: - Lifecycle

    /// Moves what the Swift Xteink path stored into the plugin's own state,
    /// once.
    ///
    /// Without it a user who already paired a reader would be asked to pair
    /// again: the pairing secret is a Keychain item under a service the plugin
    /// cannot read, and the peripheral identifier lives in the App-Group
    /// defaults. Both are copied, never moved — Luna Reader keeps the Swift
    /// path and reads the same two.
    public static func install(
        secrets: PluginSecretsStore = .shared,
        keyValueStore: PluginKVStore = .shared,
        pairingStore: any XteinkPairingStoring = XteinkKeychainPairingStore(),
        pairedDevices: PluginPairedDeviceStore = PluginPairedDeviceStore()
    ) {
        let migratedKey = "_migratedFromSwift"
        guard keyValueStore.valueJSON(
            pluginID: xteinkPluginID, key: migratedKey) == nil
        else { return }
        keyValueStore.setValueJSON(
            "true", pluginID: xteinkPluginID, key: migratedKey, now: Date())

        if let secret = pairingStore.credential(for: XteinkPluginMigration.hostID) {
            secrets.setSecret(
                secret, pluginID: xteinkPluginID,
                key: XteinkPluginMigration.pairingSecretKey)
        }
        if let identifier = XteinkSendSettings.pairedPeripheralID {
            pairedDevices.add(
                PluginBluetoothDevice(
                    id: identifier, name: nil,
                    serviceUUIDs: [XteinkSyncProtocol.service.uuidString]),
                pluginID: xteinkPluginID,
                settingKey: XteinkPluginMigration.deviceSettingKey)
        }
        if XteinkSendSettings.isEnabled {
            try? PluginPlatformServices.settings?.setValueJSON(
                "true", pluginID: xteinkPluginID,
                key: XteinkPluginMigration.enabledSettingKey)
        }
    }

    /// Opens every set-up plugin's standing connect and scan. A device
    /// advertises for a short window after a wake, so the central has to be
    /// live before it does.
    public static func appDidLaunch() {
        centers?.startAll()
    }

    /// A restored central can become ready long after launch, and a foreground
    /// is the cheapest moment to re-open a scan that a power cycle closed.
    public static func sceneDidForeground() {
        centers?.startAll()
    }
}

/// What the one-time Xteink migration reads and writes. The names are the
/// bundled `xteink.js` manifest's own; a change there changes these.
enum XteinkPluginMigration {
    /// The `host_id` the reader stores and the HMAC hello signs over. The
    /// Swift path's pairing secret is keyed by it in the Keychain, and the
    /// plugin must keep using it or a paired reader stops authenticating.
    static let hostID = "luna-ios"
    static let pairingSecretKey = "pairingSecret"
    static let deviceSettingKey = "device"
    static let enabledSettingKey = "enabled"
}
