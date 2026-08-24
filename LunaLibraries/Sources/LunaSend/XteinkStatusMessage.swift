//
//  XteinkStatusMessage.swift
//  Luna
//

import Foundation

/// One decoded status notification from the reader. Every field mirrors a
/// JSON key the device may or may not send in a given message — a status is
/// size-capped by BLE (MTU−3 bytes), so no message carries every field at
/// once, and a parser must tolerate any subset being absent.
public struct XteinkStatusMessage {
    public let nonce: String?
    public let received: Int?
    public let resumeOffset: Int?
    public let nextSequence: UInt32?
    public let ok: Bool?
    public let error: String?
    public let opAck: String?
    public let wifi: XteinkWiFiOffer?
    /// Finished-reading ids the device is handing back, at most 2 per message
    /// (the device's own size cap). A malformed entry is skipped rather than
    /// failing the whole message.
    public let readIDs: [UUID]
    /// Whether this status was published during a read-report ping window
    /// (`"win":"rr"`) rather than a manual-sync or pairing window.
    public let isReadReportWindow: Bool

    /// The device rejects an operation either with an explicit `ok:false`, or
    /// with a non-empty `error` — both forms appear on the wire.
    public var isFailure: Bool { ok == false || (error?.isEmpty == false) }

    public static func parse(_ data: Data) -> XteinkStatusMessage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var wifiOffer: XteinkWiFiOffer?
        if let wifi = json["wifi"] as? [String: Any], let mode = wifi["mode"] as? String,
           let offerMode = XteinkWiFiOffer.Mode(rawValue: mode), let ip = wifi["ip"] as? String {
            wifiOffer = XteinkWiFiOffer(
                mode: offerMode, ssid: wifi["ssid"] as? String ?? "",
                passphrase: wifi["password"] as? String ?? "", host: ip)
        }
        let readIDs = (json["read_ids"] as? [String])?.compactMap(UUID.init(uuidString:)) ?? []
        return XteinkStatusMessage(
            nonce: json["nonce"] as? String,
            received: json["received"] as? Int,
            resumeOffset: json["resume_offset"] as? Int,
            nextSequence: (json["next_sequence"] as? Int).map { UInt32(clamping: $0) },
            ok: json["ok"] as? Bool,
            error: json["error"] as? String,
            opAck: json["op_ack"] as? String,
            wifi: wifiOffer,
            readIDs: readIDs,
            isReadReportWindow: (json["win"] as? String) == "rr")
    }
}
