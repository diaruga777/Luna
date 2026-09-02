//
//  SystemPluginWiFiJoiner.swift
//  LunaPluginTransport
//

import Foundation
import Network
#if os(iOS)
import NetworkExtension
import UIKit
#endif

/// The shipped `luna.wifi`: `NEHotspotConfiguration` to join a device's own
/// access point, and an `NWConnection` probe to ask whether a host answers.
///
/// The configuration is removed after the transfer, so the phone reassociates
/// with its usual network without the user cleaning up.
public final class SystemPluginWiFiJoiner: PluginWiFiJoining {

    /// Seconds to wait before a second apply. A device publishes its
    /// credentials over BLE, releases BLE, and only then brings the access
    /// point up, so a first apply can race the SSID's appearance.
    static let reapplyPause: TimeInterval = 3

    public init() {}

    public var isForeground: Bool {
        #if os(iOS)
        guard !Thread.isMainThread else {
            return UIApplication.shared.applicationState == .active
        }
        return DispatchQueue.main.sync { UIApplication.shared.applicationState == .active }
        #else
        return true
        #endif
    }

    public func join(
        ssid: String, passphrase: String?, joinOnce: Bool,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        #if os(iOS)
        apply(ssid: ssid, passphrase: passphrase, joinOnce: joinOnce) { [self] first in
            guard case .failure = first else { return completion(first) }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.reapplyPause) { [self] in
                apply(ssid: ssid, passphrase: passphrase, joinOnce: joinOnce, completion)
            }
        }
        #else
        completion(.failure(PluginTransportError(
            code: "unavailable-here", message: "joining a network needs iOS")))
        #endif
    }

    public func forget(ssid: String) {
        #if os(iOS)
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        #endif
    }

    public func isReachable(
        host: String, port: Int, timeout: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return completion(false)
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let latch = OperationLatch()
        let finish: (Bool) -> Void = { reachable in
            guard latch.take() else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(reachable)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        connection.start(queue: DispatchQueue.global())
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    #if os(iOS)
    private func apply(
        ssid: String, passphrase: String?, joinOnce: Bool,
        _ completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        let configuration: NEHotspotConfiguration
        if let passphrase, !passphrase.isEmpty {
            configuration = NEHotspotConfiguration(
                ssid: ssid, passphrase: passphrase, isWEP: false)
        } else {
            configuration = NEHotspotConfiguration(ssid: ssid)
        }
        configuration.joinOnce = joinOnce
        NEHotspotConfigurationManager.shared.apply(configuration) { error in
            guard let error,
                  (error as NSError).code != NEHotspotConfigurationError.alreadyAssociated.rawValue
            else { return completion(.success(())) }
            completion(.failure(PluginTransportError(
                code: "join-failed", message: "\(error)")))
        }
    }
    #endif
}
