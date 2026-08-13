//
//  KindleSendSettings.swift
//  Luna
//

import Foundation
import LunaMailAccount
import LunaStorage

/// Send-to-Kindle configuration, persisted in the shared App-Group suite so the
/// central app and the Reader send to one Kindle address. Kindle sending goes out
/// through the connected Luna email account (`EmailAccountStore`) — the same
/// account used for sign-in and friend sharing — so there is no separate SMTP
/// credential here. The account's address must be on Amazon's approved-sender
/// list for delivery to succeed.
public enum KindleSendSettings {

    /// Send timing is the shared `ArticleSendMode`.
    public typealias SendMode = ArticleSendMode

    private static let modeKey = "kindleSendMode"
    private static let kindleAddressKey = "kindleAddress"

    /// Overridable so tests can drive both halves of the read-through without
    /// touching the real container. Production code never sets it.
    static var testDefaultsOverride: MigratingAppGroupDefaults?

    private static var defaults: MigratingAppGroupDefaults {
        testDefaultsOverride ?? MigratingAppGroupDefaults()
    }

    /// The "Also Send to Kindle" toggle. Shared with the mail importer
    /// (`IncomingMailSettings.autoSendToKindle` reads/writes the same key), so the
    /// send layer can consult it without depending on the mail layer.
    public static var autoSendToKindle: Bool {
        get { defaults.bool(forKey: "incomingMailAutoSendToKindle") }
        set { defaults.set(newValue, forKey: "incomingMailAutoSendToKindle") }
    }

    public static var sendMode: SendMode {
        get { SendMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    /// The user's @kindle.com inbox address.
    public static var kindleAddress: String {
        get { defaults.string(forKey: kindleAddressKey) ?? "" }
        set { defaults.set(newValue, forKey: kindleAddressKey) }
    }

    /// True when everything needed to actually send is present: a Kindle address
    /// and a connected email account to send it through.
    public static var isConfigured: Bool {
        !kindleAddress.isEmpty && EmailAccountStore.shared.isReady
    }
}
