//
//  PluginWiFiBridge.swift
//  LunaPluginTransport
//

import Foundation
import JavaScriptCore
import LunaPluginKit
import LunaPluginRuntime

/// Joining a device's own network, leaving it, and asking whether a host
/// answers. A test hands over its own.
public protocol PluginWiFiJoining: AnyObject {
    /// iOS applies a hotspot configuration only while the app is in the
    /// foreground. The fact lives here so a plugin does not have to guess it:
    /// `join` refuses with code `background` and the plugin notifies instead.
    var isForeground: Bool { get }
    func join(
        ssid: String, passphrase: String?, joinOnce: Bool,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void)
    func forget(ssid: String)
    func isReachable(
        host: String, port: Int, timeout: TimeInterval,
        completion: @escaping (Bool) -> Void)
}

/// `luna.wifi` (§10.3): the join a device's own access point needs, and the
/// reachability probe that says whether the upload can start.
///
/// The upload itself is `luna.fetch` with a `multipart` body — nothing here
/// moves bytes.
public final class PluginWiFiBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.wifi

    static let defaultProbeTimeout: TimeInterval = 3

    private let processKind: PluginProcessKind
    private let scheduler: PluginCallbackScheduling
    private let joiner: any PluginWiFiJoining

    public init(
        processKind: PluginProcessKind, scheduler: PluginCallbackScheduling,
        joiner: any PluginWiFiJoining
    ) {
        self.processKind = processKind
        self.scheduler = scheduler
        self.joiner = joiner
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let scheduler = self.scheduler
        let joiner = self.joiner

        guard processKind == .app else {
            PluginUnavailableBridge.installRefusing(
                capabilityName, reason: "luna.wifi is available in the app only",
                into: namespace)
            return
        }

        let join: @convention(block) (JSValue?) -> JSValue? = { options in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            let object = PluginBridgeValue.dictionary(options)
            guard let ssid = PluginBridgeValue.string(object, "ssid") else {
                box.fail("luna.wifi.join needs an ssid", code: "bad-argument")
                return promise
            }
            guard joiner.isForeground else {
                box.fail(
                    "iOS joins a network only while Luna is in the foreground",
                    code: "background")
                return promise
            }
            joiner.join(
                ssid: ssid, passphrase: PluginBridgeValue.string(object, "passphrase"),
                joinOnce: PluginBridgeValue.bool(object, "joinOnce") ?? true
            ) { result in
                switch result {
                case .success: box.fulfill(["joined": true])
                case .failure(let error): box.fail(error.message, code: error.code)
                }
            }
            return promise
        }

        let forget: @convention(block) (String?) -> JSValue? = { ssid in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let ssid, !ssid.isEmpty else {
                box.fail("luna.wifi.forget needs an ssid", code: "bad-argument")
                return promise
            }
            joiner.forget(ssid: ssid)
            box.fulfill(NSNull())
            return promise
        }

        let isReachable: @convention(block) (String?, JSValue?, JSValue?) -> JSValue? = {
            host, port, options in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let host, !host.isEmpty,
                  let portNumber = port?.toNumber()?.intValue, portNumber > 0, portNumber < 65_536
            else {
                box.fail("luna.wifi.isReachable needs a host and a port", code: "bad-argument")
                return promise
            }
            let timeout = PluginBridgeValue.double(
                PluginBridgeValue.dictionary(options), "timeout") ?? Self.defaultProbeTimeout
            joiner.isReachable(host: host, port: portNumber, timeout: timeout) { reachable in
                box.fulfill(reachable)
            }
            return promise
        }

        let wifi = namespace.makeNamespaceObject()
        wifi.setObject(join, forKeyedSubscript: "join" as NSString)
        wifi.setObject(forget, forKeyedSubscript: "forget" as NSString)
        wifi.setObject(isReachable, forKeyedSubscript: "isReachable" as NSString)
        namespace.install(wifi, as: capabilityName.rawValue)
    }
}
