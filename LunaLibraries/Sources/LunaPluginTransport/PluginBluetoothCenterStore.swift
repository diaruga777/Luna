//
//  PluginBluetoothCenterStore.swift
//  LunaPluginTransport
//

import Foundation
import LunaPluginKit
import LunaStorage

/// Builds the four things a `PluginBluetoothCenter` needs. One witness rather
/// than four stored closures; a test hands over its own.
public protocol PluginTransportMaking: AnyObject {
    func makeTransport(pluginID: String) -> any PluginBluetoothTransporting
    func makePairing(pluginID: String) -> (any PluginAccessoryPairing)?
    func makeServiceLock(serviceUUID: String) -> BluetoothServiceLock
    func makeLease() -> (any PluginBackgroundLeasing)?
}

/// The centers this process holds, one per plugin that declares `bluetooth`.
///
/// A center is built when the plugin's bridge installs — at load, before any
/// hook runs — so `appDidLaunch()` has something to start. It outlives its
/// JavaScript context: iOS may restore the manager and connect long after the
/// context that asked for it was rebuilt.
public final class PluginBluetoothCenterStore: @unchecked Sendable {

    private let makers: any PluginTransportMaking
    private let pairedDevices: PluginPairedDeviceStore
    /// Set only by a test; production centers read
    /// `PluginPlatformServices.invoker`.
    private let invoker: (any PluginHookInvoking)?

    private let lock = NSLock()
    private var centers: [String: PluginBluetoothCenter] = [:]

    public init(
        makers: any PluginTransportMaking,
        pairedDevices: PluginPairedDeviceStore = PluginPairedDeviceStore(),
        invoker: (any PluginHookInvoking)? = nil
    ) {
        self.makers = makers
        self.pairedDevices = pairedDevices
        self.invoker = invoker
    }

    /// The center for `pluginID`, built on first ask.
    @discardableResult
    public func center(
        pluginID: String, declaration: PluginBluetoothDeclaration,
        pairedDeviceSettingKey: String?, settingFields: [PluginSettingField] = []
    ) -> PluginBluetoothCenter {
        lock.lock()
        defer { lock.unlock() }
        if let existing = centers[pluginID] { return existing }
        let center = PluginBluetoothCenter(
            pluginID: pluginID,
            declaration: declaration,
            makers: makers,
            pairedDevices: pairedDevices,
            pairedDeviceSettingKey: pairedDeviceSettingKey,
            settingFields: settingFields,
            invoker: invoker)
        centers[pluginID] = center
        return center
    }

    public func existingCenter(pluginID: String) -> PluginBluetoothCenter? {
        lock.lock()
        defer { lock.unlock() }
        return centers[pluginID]
    }

    public var all: [PluginBluetoothCenter] {
        lock.lock()
        defer { lock.unlock() }
        return Array(centers.values)
    }

    /// Opens the standing connect and scan of every center the user has set
    /// up. A plugin nobody paired opens no scan, so it triggers no Bluetooth
    /// permission prompt.
    public func startAll() {
        for center in all where center.isPermittedToStart { center.start() }
    }
}
