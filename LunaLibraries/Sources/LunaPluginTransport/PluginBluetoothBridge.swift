//
//  PluginBluetoothBridge.swift
//  LunaPluginTransport
//

import Foundation
import JavaScriptCore
import LunaPluginKit
import LunaPluginRuntime

/// `luna.bluetooth` (§10.2): the radio, the pairing step, and a live session.
///
/// The hook receives its session through `luna.bluetooth.session()` rather than
/// as a second argument: a hook is called with exactly one JSON argument, so a
/// native object cannot ride along with the event. The center keeps the session
/// live for the whole `onBluetooth` invocation, including an `export` call
/// nested inside it, which is what a destination plugin's
/// `luna.exports.deliverQueued()` produces.
///
/// The bridge is installed in every process so a declared capability stays
/// visible; outside the app every call rejects with `unavailable-here`.
public final class PluginBluetoothBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.bluetooth

    /// Default seconds `connect` waits for a link.
    static let defaultConnectTimeout: TimeInterval = 20
    /// Default seconds `next` waits for a notification.
    static let defaultNextTimeout: TimeInterval = 10

    private let processKind: PluginProcessKind
    private let scheduler: PluginCallbackScheduling
    private let centers: PluginBluetoothCenterStore

    public init(
        processKind: PluginProcessKind, scheduler: PluginCallbackScheduling,
        centers: PluginBluetoothCenterStore
    ) {
        self.processKind = processKind
        self.scheduler = scheduler
        self.centers = centers
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let scheduler = self.scheduler
        let manifest = namespace.target.manifest
        let bluetooth = namespace.makeNamespaceObject()

        guard processKind == .app, let declaration = manifest.bluetooth else {
            PluginUnavailableBridge.installRefusing(
                capabilityName, reason: processKind == .app
                    ? "this plugin declares no bluetooth services"
                    : "luna.bluetooth is available in the app only",
                into: namespace)
            return
        }
        let center = centers.center(
            pluginID: manifest.id, declaration: declaration,
            pairedDeviceSettingKey: manifest.settings
                .first { $0.type == .pairedDevice }?.key,
            settingFields: manifest.settings)
        let displayName = manifest.name

        let state: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            box.fulfill(center.state.rawValue)
            return promise
        }

        let pair: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            center.pair(displayName: displayName) { result in
                switch result {
                case .success(let device):
                    box.fulfill(device?.jsObject ?? NSNull())
                case .failure(let error):
                    box.fail(error.message, code: error.code)
                }
            }
            return promise
        }

        let pairedDevices: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            box.fulfill(center.knownDevices().map(\.jsObject))
            return promise
        }

        let unpair: @convention(block) (String?) -> JSValue? = { deviceID in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let deviceID, !deviceID.isEmpty else {
                box.fail("luna.bluetooth.unpair needs a device id", code: "bad-argument")
                return promise
            }
            center.unpair(deviceID: deviceID) { box.fulfill(NSNull()) }
            return promise
        }

        let connect: @convention(block) (String?, JSValue?) -> JSValue? = { deviceID, options in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let deviceID, !deviceID.isEmpty else {
                box.fail("luna.bluetooth.connect needs a device id", code: "bad-argument")
                return promise
            }
            let timeout = PluginBridgeValue.double(
                PluginBridgeValue.dictionary(options), "timeout")
                ?? Self.defaultConnectTimeout
            center.connect(deviceID: deviceID, timeout: timeout) { result in
                switch result {
                case .success(let session):
                    box.fulfill(PluginBluetoothSessionJS.object(
                        for: session, in: context, scheduler: scheduler) as Any)
                case .failure(let error):
                    box.fail(error.message, code: error.code)
                }
            }
            return promise
        }

        // Synchronous on purpose: the answer is "is a link live right now",
        // and a hook that had to await it could not tell "no session" from
        // "not yet".
        let session: @convention(block) () -> Any? = {
            let context = JSContext.current() ?? outerContext
            guard let live = center.liveSession, live.isLive else { return NSNull() }
            return PluginBluetoothSessionJS.object(
                for: live, in: context, scheduler: scheduler) as Any
        }

        bluetooth.setObject(state, forKeyedSubscript: "state" as NSString)
        bluetooth.setObject(pair, forKeyedSubscript: "pair" as NSString)
        bluetooth.setObject(pairedDevices, forKeyedSubscript: "pairedDevices" as NSString)
        bluetooth.setObject(unpair, forKeyedSubscript: "unpair" as NSString)
        bluetooth.setObject(connect, forKeyedSubscript: "connect" as NSString)
        bluetooth.setObject(session, forKeyedSubscript: "session" as NSString)
        namespace.install(bluetooth, as: capabilityName.rawValue)
    }
}

/// A `BluetoothSession` as JavaScript sees it.
enum PluginBluetoothSessionJS {

    static func object(
        for session: PluginBluetoothSession, in context: JSContext,
        scheduler: PluginCallbackScheduling
    ) -> JSValue {
        let object = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)!

        let discover: @convention(block) (String?) -> JSValue? = { serviceUUID in
            let context = JSContext.current() ?? context
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let serviceUUID, !serviceUUID.isEmpty else {
                box.fail("discover needs a service UUID", code: "bad-argument")
                return promise
            }
            session.discover(serviceUUID: serviceUUID) { result in
                switch result {
                case .success(let characteristics):
                    box.fulfill(["characteristics": characteristics])
                case .failure(let error):
                    box.fail(error.message, code: error.code)
                }
            }
            return promise
        }

        let read: @convention(block) (String?) -> JSValue? = { characteristicUUID in
            let context = JSContext.current() ?? context
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let characteristicUUID, !characteristicUUID.isEmpty else {
                box.fail("read needs a characteristic UUID", code: "bad-argument")
                return promise
            }
            session.read(characteristicUUID: characteristicUUID) { result in
                settle(result, box)
            }
            return promise
        }

        let write: @convention(block) (String?, String?, JSValue?) -> JSValue? = {
            characteristicUUID, base64, options in
            let context = JSContext.current() ?? context
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let characteristicUUID, !characteristicUUID.isEmpty, let base64 else {
                box.fail("write needs a characteristic UUID and base64", code: "bad-argument")
                return promise
            }
            let withResponse = PluginBridgeValue.bool(
                PluginBridgeValue.dictionary(options), "response") ?? true
            session.write(
                base64: base64, characteristicUUID: characteristicUUID,
                withResponse: withResponse
            ) { result in settleVoid(result, box) }
            return promise
        }

        let subscribe: @convention(block) (String?) -> JSValue? = { characteristicUUID in
            let context = JSContext.current() ?? context
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let characteristicUUID, !characteristicUUID.isEmpty else {
                box.fail("subscribe needs a characteristic UUID", code: "bad-argument")
                return promise
            }
            session.subscribe(characteristicUUID: characteristicUUID) { result in
                settleVoid(result, box)
            }
            return promise
        }

        let next: @convention(block) (String?, JSValue?) -> JSValue? = {
            characteristicUUID, options in
            let context = JSContext.current() ?? context
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let characteristicUUID, !characteristicUUID.isEmpty else {
                box.fail("next needs a characteristic UUID", code: "bad-argument")
                return promise
            }
            let timeout = PluginBridgeValue.double(
                PluginBridgeValue.dictionary(options), "timeout")
                ?? PluginBluetoothBridge.defaultNextTimeout
            session.next(characteristicUUID: characteristicUUID, timeout: timeout) { result in
                settle(result, box)
            }
            return promise
        }

        let disconnect: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? context
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            session.disconnect { result in settleVoid(result, box) }
            return promise
        }

        object.setObject(session.device.jsObject, forKeyedSubscript: "device" as NSString)
        object.setObject(session.mtu, forKeyedSubscript: "mtu" as NSString)
        object.setObject(discover, forKeyedSubscript: "discover" as NSString)
        object.setObject(read, forKeyedSubscript: "read" as NSString)
        object.setObject(write, forKeyedSubscript: "write" as NSString)
        object.setObject(subscribe, forKeyedSubscript: "subscribe" as NSString)
        object.setObject(next, forKeyedSubscript: "next" as NSString)
        object.setObject(disconnect, forKeyedSubscript: "disconnect" as NSString)
        return object
    }

    private static func settle(
        _ result: Result<String, PluginTransportError>, _ box: PluginPromiseBox
    ) {
        switch result {
        case .success(let value): box.fulfill(value)
        case .failure(let error): box.fail(error.message, code: error.code)
        }
    }

    private static func settleVoid(
        _ result: Result<Void, PluginTransportError>, _ box: PluginPromiseBox
    ) {
        switch result {
        case .success: box.fulfill(NSNull())
        case .failure(let error): box.fail(error.message, code: error.code)
        }
    }
}

/// A namespace whose every member rejects, for a declared capability this
/// process cannot serve.
///
/// The runtime's own stand-in cannot be reached from here, and the grant
/// read-back needs the name installed either way (§7.2), so the transport tier
/// builds its own with the same shape: a `Proxy` over a function, so a
/// namespace that is both called and read from refuses on either.
enum PluginUnavailableBridge {

    static func installRefusing(
        _ name: PluginCapabilityName, reason: String, into namespace: PluginCapabilityNamespace
    ) {
        let context = namespace.context
        guard let factory = context.evaluateScript(
            """
            (function (ns, reason) {
                function refuse(member) {
                    const where = member ? "luna." + ns + "." + member : "luna." + ns;
                    return Promise.reject(
                        new luna.LunaError("unavailable-here", where + ": " + reason));
                }
                return new Proxy(function () {}, {
                    apply: function () { return refuse(null); },
                    get: function (_target, property) {
                        if (property === "then") { return undefined; }
                        return function () { return refuse(String(property)); };
                    }
                });
            })
            """)
        else { return }
        let object = factory.call(withArguments: [name.rawValue, reason])
        namespace.install(object ?? JSValue(undefinedIn: context) as Any, as: name.rawValue)
    }
}
