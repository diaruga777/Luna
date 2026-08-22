//
//  XteinkSendSettings.swift
//  Luna
//

import Foundation
import LunaModels
import LunaStorage

/// Send-to-Xteink configuration, persisted in the shared App-Group suite so the
/// central app and the Reader push to one device. Delivery is a direct HTTP
/// upload to the e-reader's own Wi-Fi file manager (`XteinkDeviceClient`), so
/// there is no account and no email requirement here — one enable switch and
/// an optional device address are the whole setup.
public enum XteinkSendSettings {

    private static let enabledKey = "xteinkEnabled"
    private static let addressKey = "xteinkDeviceAddress"
    private static let modeKey = "xteinkSendMode"

    /// The stock firmware's mDNS hostname. Tried last, after any address the
    /// user typed, so a DHCP-reserved IP gets the faster path.
    public static let defaultDeviceAddress = "E-Paper.local"

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

    /// The device hostname or IP the user typed. Empty means "use the default
    /// mDNS name only".
    public static var deviceAddress: String {
        get { defaults.string(forKey: addressKey) ?? "" }
        set { defaults.set(newValue, forKey: addressKey) }
    }

    /// Candidate hosts in probe order: each address the user typed (comma or
    /// whitespace separated), then the firmware's default mDNS name.
    public static var candidateHosts: [String] {
        var hosts = deviceAddress
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        if !hosts.contains(defaultDeviceAddress) {
            hosts.append(defaultDeviceAddress)
        }
        return hosts
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

    public static var isConfigured: Bool { isEnabled }
}
