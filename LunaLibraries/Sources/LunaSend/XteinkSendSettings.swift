//
//  XteinkSendSettings.swift
//  Luna
//

import Foundation
import LunaModels
import LunaStorage

/// Send-to-Xteink configuration, persisted in the shared App-Group suite so the
/// central app and the Reader push to one device. Delivery goes over the
/// CrossPoint BLE rendezvous or a same-network CrossPoint HTTP upload (see
/// `XteinkCrossPointTransferRouter`), so there is no account and no email
/// requirement here — one enable switch and BLE pairing are the whole setup.
public enum XteinkSendSettings {

    private static let enabledKey = "xteinkEnabled"
    private static let modeKey = "xteinkSendMode"
    private static let peripheralIDKey = "xteinkPeripheralID"

    /// Overridable so tests can drive both halves of the read-through without
    /// touching the real container. Production code never sets it.
    static var testDefaultsOverride: MigratingAppGroupDefaults?

    private static var defaults: MigratingAppGroupDefaults {
        testDefaultsOverride ?? MigratingAppGroupDefaults()
    }

    /// The one enable switch. Off by default: an unconfigured install must not
    /// probe the local network (that alone triggers the iOS permission prompt).
    public static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// The App Intents / in-app save mode. Defaults to `.allSaves`: the enable
    /// switch is the consent step, and delivery is opportunistic anyway — a
    /// queued save costs nothing until the device is awake to receive it.
    public static var sendMode: ArticleSendMode {
        get {
            defaults.string(forKey: modeKey)
                .flatMap(ArticleSendMode.init(rawValue:)) ?? .allSaves
        }
        set { defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    /// The reader's CoreBluetooth identifier from the last successful
    /// connection. `XteinkBLECentral` keeps a standing connect to it, which
    /// completes the instant the reader advertises — no scan-discovery race —
    /// and survives ordinary app termination through state restoration.
    public static var pairedPeripheralID: String? {
        get { defaults.string(forKey: peripheralIDKey) }
        set { defaults.set(newValue, forKey: peripheralIDKey) }
    }

    /// Repair only known legacy transport failures and ambiguous newsletter
    /// receipts. Distinct saves sharing a basename were previously all marked
    /// sent on `exists`; the new save-ID names make the repair idempotent.
    public static func repairLegacySyncQueue(store: SavesStore = .shared) {
        let destination = ArticleDestinationID.xteink
        let items = store.items()
        let receipts = Dictionary(grouping: items.filter {
            $0.remoteName(for: destination) != nil
        }, by: { $0.remoteName(for: destination)! })
        for item in items where item.state == .ready && item.readState != .read {
            let state = item.sendState(for: destination)
            let error = (item.sendLastErrors[destination] ?? "").lowercased()
            let transient = state == .failed && [
                "checkpoint", "timed out", "timed-out", "resume_mismatch", "low_memory", "sequence"
            ].contains(where: error.contains)
            let collision = state == .sent && item.effectiveCaptureSource == .email &&
                item.remoteName(for: destination).map { name in
                    !name.contains(item.id.uuidString.lowercased()) && (receipts[name]?.count ?? 0) > 1
                } == true
            if transient || collision {
                store.setSendState(.queued, for: item.id, destination: destination)
            }
        }
    }

    public static var isConfigured: Bool { isEnabled }
}
