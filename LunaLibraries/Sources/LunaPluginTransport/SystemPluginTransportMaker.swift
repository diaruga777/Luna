//
//  SystemPluginTransportMaker.swift
//  LunaPluginTransport
//

import CoreBluetooth
import Foundation
import LunaStorage
#if os(iOS)
import AccessorySetupKit
import UIKit
#endif

/// The shipped witnesses: a CoreBluetooth transport, an AccessorySetupKit
/// pairing step, the service's App-Group lock, and a UIKit background lease.
public final class SystemPluginTransportMaker: PluginTransportMaking {

    public init() {}

    public func makeTransport(pluginID: String) -> any PluginBluetoothTransporting {
        CoreBluetoothPluginTransport(pluginID: pluginID)
    }

    public func makePairing(pluginID: String) -> (any PluginAccessoryPairing)? {
        #if os(iOS)
        return AccessorySetupKitPairing()
        #else
        return nil
        #endif
    }

    public func makeServiceLock(serviceUUID: String) -> BluetoothServiceLock {
        BluetoothServiceLock.shared(serviceUUID: serviceUUID)
    }

    public func makeLease() -> (any PluginBackgroundLeasing)? {
        #if os(iOS)
        return UIApplicationBackgroundLease()
        #else
        return nil
        #endif
    }
}

#if os(iOS)

/// AccessorySetupKit's picker, scoped to a plugin's declared services.
///
/// The order the pair flow keeps is fixed by two traps. `showPicker` fails
/// while the process holds any live `CBManager` (ASErrorDomain 550), and it
/// never lists an accessory it considers already set up — a stale
/// authorization reads to the user as "iPhone can't find the accessory", and
/// the bond iOS kept alongside it no longer matches the device's cleared keys.
/// So every prior authorization is removed first, which deletes that bond too.
public final class AccessorySetupKitPairing: PluginAccessoryPairing {

    private var session: ASAccessorySession?
    private var isActivated = false
    private var pickerCompletion: ((Result<PluginBluetoothDevice?, PluginTransportError>) -> Void)?
    private let latchLock = NSLock()

    public init() {}

    private func activatedSession() -> ASAccessorySession {
        if let session { return session }
        let session = ASAccessorySession()
        self.session = session
        session.activate(on: .main) { [weak self] event in self?.handle(event) }
        return session
    }

    /// `ASAccessorySession.accessories` is EMPTY until the session's
    /// `.activated` event lands, so anything enumerating it must wait.
    private func awaitActivation(_ completion: @escaping () -> Void) {
        _ = activatedSession()
        poll(remaining: 50, completion)
    }

    private func poll(remaining: Int, _ completion: @escaping () -> Void) {
        guard !isActivated, remaining > 0 else { return completion() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.poll(remaining: remaining - 1, completion)
        }
    }

    public func showPicker(
        serviceUUIDs: [String], displayName: String,
        completion: @escaping (Result<PluginBluetoothDevice?, PluginTransportError>) -> Void
    ) {
        let descriptors = serviceUUIDs.compactMap(CoreBluetoothPluginTransport.uuid(from:))
        guard let first = descriptors.first else {
            return completion(.failure(.unavailable("no valid service UUID to look for")))
        }
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = first
        let item = ASPickerDisplayItem(
            name: displayName,
            productImage: UIImage(systemName: "dot.radiowaves.left.and.right") ?? UIImage(),
            descriptor: descriptor)
        latchLock.lock()
        pickerCompletion = completion
        latchLock.unlock()
        Task { @MainActor [self] in
            do {
                try await activatedSession().showPicker(for: [item])
                // A selection arrives through `.accessoryAdded`; a dismissed
                // picker reports nothing at all. Answer nil shortly after, so
                // the caller is never left waiting on a picker that is gone.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                    settle(.success(nil))
                }
            } catch {
                settle(.failure(.unavailable("\(error)")))
            }
        }
    }

    public func removeSetUpAccessories(completion: @escaping () -> Void) {
        awaitActivation { [self] in
            let accessories = activatedSession().accessories
            guard !accessories.isEmpty else { return completion() }
            Task { @MainActor [self] in
                for accessory in accessories {
                    try? await activatedSession().removeAccessory(accessory)
                }
                completion()
            }
        }
    }

    public func removeAccessory(deviceID: String, completion: @escaping () -> Void) {
        awaitActivation { [self] in
            let match = activatedSession().accessories.first {
                $0.bluetoothIdentifier?.uuidString == deviceID
            }
            guard let match else { return completion() }
            Task { @MainActor [self] in
                try? await activatedSession().removeAccessory(match)
                completion()
            }
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        if event.eventType == .activated { isActivated = true }
        guard event.eventType == .accessoryAdded,
              let accessory = event.accessory,
              let identifier = accessory.bluetoothIdentifier
        else { return }
        settle(.success(PluginBluetoothDevice(
            id: identifier.uuidString, name: accessory.displayName, serviceUUIDs: [])))
    }

    private func settle(_ result: Result<PluginBluetoothDevice?, PluginTransportError>) {
        latchLock.lock()
        let completion = pickerCompletion
        pickerCompletion = nil
        latchLock.unlock()
        completion?(result)
    }
}

/// `UIApplication.beginBackgroundTask`, so a hook the radio woke finishes
/// rather than being suspended halfway through a transfer.
public final class UIApplicationBackgroundLease: PluginBackgroundLeasing {

    private let lock = NSLock()
    private var identifiers: [Int: UIBackgroundTaskIdentifier] = [:]
    private var nextToken = 0

    public init() {}

    public func beginLease(name: String) -> Int? {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.endExpired(name: name)
        }
        guard identifier != .invalid else { return nil }
        lock.lock()
        defer { lock.unlock() }
        nextToken += 1
        identifiers[nextToken] = identifier
        return nextToken
    }

    public func endLease(_ token: Int) {
        lock.lock()
        let identifier = identifiers.removeValue(forKey: token)
        lock.unlock()
        guard let identifier else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }

    /// iOS is reclaiming the lease. Ending every one this lease holds is the
    /// only answer available: the hook cannot be interrupted.
    private func endExpired(name: String) {
        lock.lock()
        let all = identifiers
        identifiers = [:]
        lock.unlock()
        for identifier in all.values { UIApplication.shared.endBackgroundTask(identifier) }
    }
}

#endif
