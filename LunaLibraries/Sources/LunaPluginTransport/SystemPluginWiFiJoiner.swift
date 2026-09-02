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

/// One hotspot configuration, applied and removed. The shipped witness is
/// `NEHotspotConfigurationManager`; a test hands over its own, so the retry
/// `SystemPluginWiFiJoiner` runs is assertable without a radio.
public protocol PluginHotspotConfiguring: AnyObject {
    func apply(
        ssid: String, passphrase: String?, joinOnce: Bool,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void)
    func remove(ssid: String)
}

/// The shipped `luna.wifi`: `NEHotspotConfiguration` to join a device's own
/// access point, and an `NWConnection` probe to ask whether a host answers.
///
/// The configuration is removed after the transfer, so the phone reassociates
/// with its usual network without the user cleaning up.
public final class SystemPluginWiFiJoiner: PluginWiFiJoining {

    /// Seconds to wait before a second apply. A device publishes its
    /// credentials over BLE, releases BLE, and only then brings the access
    /// point up, so a first apply can race the SSID's appearance.
    public static let defaultReapplyPause: TimeInterval = 3

    private let configurator: any PluginHotspotConfiguring
    private let reapplyPause: TimeInterval

    public init(
        configurator: (any PluginHotspotConfiguring)? = nil,
        reapplyPause: TimeInterval = SystemPluginWiFiJoiner.defaultReapplyPause
    ) {
        self.configurator = configurator ?? SystemHotspotConfigurator()
        self.reapplyPause = reapplyPause
    }

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
        configurator.apply(ssid: ssid, passphrase: passphrase, joinOnce: joinOnce) { [self] first in
            guard case .failure = first else { return completion(first) }
            DispatchQueue.global().asyncAfter(deadline: .now() + reapplyPause) { [self] in
                configurator.apply(
                    ssid: ssid, passphrase: passphrase, joinOnce: joinOnce,
                    completion: completion)
            }
        }
    }

    public func forget(ssid: String) {
        configurator.remove(ssid: ssid)
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
}

#if os(iOS)

/// `NEHotspotConfigurationManager`. An `alreadyAssociated` answer is the phone
/// already being on that network, which is the outcome the caller wanted.
final class SystemHotspotConfigurator: PluginHotspotConfiguring {

    func apply(
        ssid: String, passphrase: String?, joinOnce: Bool,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
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

    func remove(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }
}

#else

/// No hotspot configuration exists off iOS, so every join refuses.
final class SystemHotspotConfigurator: PluginHotspotConfiguring {

    func apply(
        ssid: String, passphrase: String?, joinOnce: Bool,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        completion(.failure(PluginTransportError(
            code: "unavailable-here", message: "joining a network needs iOS")))
    }

    func remove(ssid: String) {}
}

#endif
