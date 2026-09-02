//
//  XteinkRendezvousSweepLock.swift
//  Luna
//

import Foundation
import LunaStorage

/// The CrossPoint sync service's cross-process lock, for the Swift sweep.
///
/// The lock itself is `BluetoothServiceLock` (LunaStorage), keyed by service
/// UUID. Central Luna reaches the same reader through the Xteink PLUGIN, whose
/// `luna.bluetooth` bridge takes the same lock for the same UUID — so the two
/// processes keep excluding each other while the Reader keeps this Swift path.
/// `BluetoothServiceLockParityTests` pins that both derive one file.
public enum XteinkRendezvousSweepLock {
    public static var shared: BluetoothServiceLock {
        BluetoothServiceLock.shared(serviceUUID: XteinkSyncProtocol.service.uuidString)
    }
}
