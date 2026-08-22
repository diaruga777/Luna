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

/// Probes the local network for a live CrossPoint file-transfer server, so an
/// explicit "send now" can try Wi-Fi before falling back to BLE. A host wins
/// only after an identity check on its `/api/status` JSON — an arbitrary
/// router admin page must never be mistaken for the reader.
public protocol XteinkLANProbing: Sendable {
    /// The first confirmed CrossPoint host, or nil when none answers.
    func reachableHost() async -> String?
}

/// Concurrently probes the two hosts a phone can reach the reader's File
/// Transfer server on: `192.168.4.1` (the ESP32 softAP gateway, whether the
/// AP is the BLE-issued `Luna-X3-*` network or CrossPoint's own hotspot), and
/// `crosspoint.local` (mDNS, when both devices share an existing LAN).
public struct XteinkCrossPointLANProber: XteinkLANProbing {
    private let session: URLSession
    private let hosts: [String]
    private let timeout: TimeInterval

    public init(
        session: URLSession = XteinkCrossPointLANProber.makeSession(),
        hosts: [String] = ["192.168.4.1", "crosspoint.local"],
        timeout: TimeInterval = 2
    ) {
        self.session = session
        self.hosts = hosts
        self.timeout = timeout
    }

    /// Fails fast rather than waiting for connectivity — the whole point of
    /// the probe is learning quickly that a host is absent.
    public static func makeSession(
        configuration: URLSessionConfiguration = .ephemeral
    ) -> URLSession {
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    public func reachableHost() async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for host in hosts {
                group.addTask { await self.isCrossPointHost(host) ? host : nil }
            }
            // First confirmed host wins; still drain the rest so the group
            // doesn't leak dangling tasks.
            var winner: String?
            for await result in group {
                if winner == nil, let result { winner = result }
            }
            return winner
        }
    }

    private func isCrossPointHost(_ host: String) async -> Bool {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = "/api/status"
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        if let device = json["device"] as? String {
            return device == "X3" || device == "X4"
        }
        return json["version"] != nil
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
    private let lanProber: any XteinkLANProbing
    private let isForeground: @Sendable () -> Bool
    private let policy: XteinkTransferSizePolicy
    /// How long an explicit "send now" waits for a BLE rendezvous to become
    /// active after kicking off a scan, before giving up and deferring.
    private let rendezvousWaitTimeout: TimeInterval
    private let rendezvousPollInterval: TimeInterval
    private let uploadRetryPause: TimeInterval

    public init(
        ble: any XteinkBLETransporting = XteinkBLECentral.shared,
        wifi: any XteinkWiFiJoining = SystemXteinkWiFiJoiner(),
        uploader: any XteinkHTTPUploading = XteinkCrossPointClient(),
        notifier: any XteinkTransferNotifying = SystemXteinkTransferNotifier(),
        lanProber: any XteinkLANProbing = XteinkCrossPointLANProber(),
        isForeground: @escaping @Sendable () -> Bool = { XteinkAppState.isForeground },
        policy: XteinkTransferSizePolicy = XteinkTransferSizePolicy(),
        rendezvousWaitTimeout: TimeInterval = 12,
        rendezvousPollInterval: TimeInterval = 0.2,
        uploadRetryPause: TimeInterval = 2
    ) {
        self.ble = ble; self.wifi = wifi; self.uploader = uploader
        self.notifier = notifier; self.lanProber = lanProber
        self.isForeground = isForeground; self.policy = policy
        self.rendezvousWaitTimeout = rendezvousWaitTimeout
        self.rendezvousPollInterval = rendezvousPollInterval
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

    /// The explicit "send now" path (an in-app share, not the ambient auto-send
    /// sweep): try the local Wi-Fi network first, since a phone that is already
    /// on the reader's AP or LAN can deliver immediately. Only when that finds
    /// nothing does it fall back to bringing up a BLE rendezvous.
    public func sendNow(_ data: Data, fileName: String, title: String) async throws {
        if XteinkSendSettings.isEnabled, let host = await lanProber.reachableHost() {
            try await uploader.upload(data, fileName: Self.x3FileName(fileName), host: host)
            return
        }
        if !ble.isRendezvousActive {
            ble.beginRendezvousScan()
            await waitForRendezvous()
        }
        try await send(data, fileName: fileName, title: title)
    }

    private func waitForRendezvous() async {
        guard rendezvousWaitTimeout > 0 else { return }
        let deadline = Date().addingTimeInterval(rendezvousWaitTimeout)
        while !ble.isRendezvousActive, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(max(0, rendezvousPollInterval) * 1_000_000_000))
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
