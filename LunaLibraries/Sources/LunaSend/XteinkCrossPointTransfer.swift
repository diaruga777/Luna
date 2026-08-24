//
//  XteinkCrossPointTransfer.swift
//  Luna
//


import Foundation
import NetworkExtension
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// CrossPoint's custom-firmware HTTP upload endpoint. This intentionally does
/// not use the stock Xteink `/edit` API: the X3 AP is owned by CrossPoint.
public protocol XteinkHTTPUploading: Sendable {
    func upload(_ data: Data, fileName: String, host: String) async throws
}

public struct XteinkCrossPointClient: XteinkHTTPUploading {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func upload(_ data: Data, fileName: String, host: String) async throws {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = "/upload"
        components.queryItems = [URLQueryItem(name: "path", value: "/Books")]
        guard let url = components.url else { throw XteinkSyncError.protocolError("invalid Wi-Fi host") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(30, 30 + Double(data.count) / 20_000)
        let boundary = "LunaCrossPoint-" + UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/epub+zip\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw XteinkSyncError.transferFailed("CrossPoint upload was rejected")
        }
    }
}

public protocol XteinkWiFiJoining: Sendable {
    func join(_ offer: XteinkWiFiOffer) async throws
    func leave(_ offer: XteinkWiFiOffer)
}

/// First-class secured AP join. iOS keeps the configuration only long enough
/// for transfer, then removing it lets the phone reassociate with its usual
/// network without user clean-up.
public struct SystemXteinkWiFiJoiner: XteinkWiFiJoining {
    public init() {}
    public func join(_ offer: XteinkWiFiOffer) async throws {
        #if os(iOS)
        // The reader publishes credentials over BLE, releases BLE, and only
        // then brings the AP up — a few seconds after this offer arrives. A
        // first apply can race the SSID's appearance, so retry once.
        do { try await apply(offer) } catch {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            try await apply(offer)
        }
        #else
        throw XteinkSyncError.unavailable
        #endif
    }

    #if os(iOS)
    private func apply(_ offer: XteinkWiFiOffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let configuration = NEHotspotConfiguration(ssid: offer.ssid, passphrase: offer.passphrase, isWEP: false)
            configuration.joinOnce = true
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                if let error, (error as NSError).code != NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
    #endif
    public func leave(_ offer: XteinkWiFiOffer) {
        #if os(iOS)
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: offer.ssid)
        #endif
    }
}

public protocol XteinkTransferNotifying: Sendable {
    func notifyWiFiTransferRequired(title: String)
}

public struct SystemXteinkTransferNotifier: XteinkTransferNotifying {
    public init() {}
    public func notifyWiFiTransferRequired(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Xteink is ready"
        content.body = "Open Luna to send \(title) over the reader’s Wi-Fi."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "xteink-wifi-transfer", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Decides the transport only after Luna has produced its final destination
/// EPUB. Small files never fall back to a speculative Wi-Fi sweep: they wait
/// for an active BLE rendezvous. Large files ask the reader for Wi-Fi details;
/// the reader itself may have selected its remembered STA before it created AP.
public final class XteinkCrossPointTransferRouter {
    private let ble: any XteinkBLETransporting
    private let wifi: any XteinkWiFiJoining
    private let uploader: any XteinkHTTPUploading
    private let notifier: any XteinkTransferNotifying
    private let isForeground: @Sendable () -> Bool
    private let policy: XteinkTransferSizePolicy
    private let uploadRetryPause: TimeInterval

    public init(
        ble: any XteinkBLETransporting = XteinkBLECentral.shared,
        wifi: any XteinkWiFiJoining = SystemXteinkWiFiJoiner(),
        uploader: any XteinkHTTPUploading = XteinkCrossPointClient(),
        notifier: any XteinkTransferNotifying = SystemXteinkTransferNotifier(),
        isForeground: @escaping @Sendable () -> Bool = { XteinkAppState.isForeground },
        policy: XteinkTransferSizePolicy = XteinkTransferSizePolicy(),
        uploadRetryPause: TimeInterval = 2
    ) {
        self.ble = ble; self.wifi = wifi; self.uploader = uploader
        self.notifier = notifier
        self.isForeground = isForeground; self.policy = policy
        self.uploadRetryPause = uploadRetryPause
    }

    public func send(_ data: Data, fileName: String, title: String) async throws {
        guard ble.isRendezvousActive else { throw XteinkSyncError.unavailable }
        let validName = Self.x3FileName(fileName)
        if policy.transport(forFinalXteinkEPUB: data) == .bluetoothLowEnergy {
            try await ble.send(data, fileName: validName, title: title, progress: { _ in })
            return
        }
        let offer = try await ble.requestWiFi()
        guard isForeground() else {
            notifier.notifyWiFiTransferRequired(title: title)
            throw XteinkSyncError.unavailable
        }
        // Registered at function scope (not inside the `if`) so the hotspot
        // configuration is removed only after the upload finishes, one way or
        // the other — never before it has had a chance to run.
        let joinedAP = offer.mode == .ap
        if joinedAP { try await wifi.join(offer) }
        defer { if joinedAP { wifi.leave(offer) } }
        do {
            try await uploader.upload(data, fileName: validName, host: offer.host)
        } catch {
            guard joinedAP else { throw error }
            // The reader binds its HTTP server moments after its AP accepts
            // the phone; one early connect can land in that gap.
            try await Task.sleep(nanoseconds: UInt64(max(0, uploadRetryPause) * 1_000_000_000))
            try await uploader.upload(data, fileName: validName, host: offer.host)
        }
    }

    public func delete(remotePath: String) async throws {
        guard ble.isRendezvousActive else { throw XteinkSyncError.unavailable }
        try await ble.delete(remotePath: remotePath)
    }

    /// CrossPoint's X3-side filename validator permits only this small ASCII
    /// set. Luna's display title remains untouched; only the transport name is
    /// normalized and kept deterministic for retries/resume.
    static func x3FileName(_ name: String) -> String {
        let permitted = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let normalized = name.unicodeScalars.map { permitted.contains($0) ? String($0) : "-" }.joined()
        return normalized.isEmpty ? "Luna.epub" : normalized
    }
}

/// UIKit is unavailable to the package's macOS build, while the actual app is
/// iOS-only. This small check keeps the router unit-testable.
public enum XteinkAppState {
    public static var isForeground: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }
}
