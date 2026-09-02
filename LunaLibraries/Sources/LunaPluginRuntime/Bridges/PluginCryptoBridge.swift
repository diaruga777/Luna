//
//  PluginCryptoBridge.swift
//  LunaPluginRuntime
//

import CryptoKit
import Foundation
import Security
import JavaScriptCore
import LunaPluginKit

/// `luna.crypto` (§6.8): the three primitives a plugin needs to speak a
/// device's own protocol — a digest, a keyed digest, and random bytes.
///
/// Binary crosses the bridge as base64, so a digest reads the same here as it
/// does through `crypto.subtle` in the Safari world.
public final class PluginCryptoBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.crypto

    private let scheduler: PluginCallbackScheduling

    public init(scheduler: PluginCallbackScheduling) {
        self.scheduler = scheduler
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let crypto = namespace.makeNamespaceObject()
        let scheduler = self.scheduler
        let pluginID = namespace.pluginID

        let sha256: @convention(block) (JSValue?) -> JSValue? = { value in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID)
            guard let data = PluginBridgeValue.data(from: value?.toObject()) else {
                box.fail("luna.crypto.sha256 needs text or { base64 }", code: "bad-argument")
                return promise
            }
            box.fulfill(Data(SHA256.hash(data: data)).base64EncodedString())
            return promise
        }

        let hmac: @convention(block) (JSValue?, JSValue?) -> JSValue? = { key, value in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID)
            guard let keyData = PluginBridgeValue.data(from: key?.toObject()),
                  let data = PluginBridgeValue.data(from: value?.toObject())
            else {
                box.fail(
                    "luna.crypto.hmacSHA256 needs a key and data", code: "bad-argument")
                return promise
            }
            let code = HMAC<SHA256>.authenticationCode(
                for: data, using: SymmetricKey(data: keyData))
            box.fulfill(Data(code).base64EncodedString())
            return promise
        }

        let random: @convention(block) (JSValue?) -> JSValue? = { count in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID)
            let requested = count?.toNumber()?.intValue ?? 0
            guard requested > 0, requested <= 1024 else {
                box.fail(
                    "luna.crypto.randomBytes takes a count between 1 and 1024",
                    code: "bad-argument")
                return promise
            }
            var bytes = [UInt8](repeating: 0, count: requested)
            guard SecRandomCopyBytes(kSecRandomDefault, requested, &bytes) == errSecSuccess else {
                box.fail("the system random source refused", code: "runtime")
                return promise
            }
            box.fulfill(Data(bytes).base64EncodedString())
            return promise
        }

        crypto.setObject(sha256, forKeyedSubscript: "sha256" as NSString)
        crypto.setObject(hmac, forKeyedSubscript: "hmacSHA256" as NSString)
        crypto.setObject(random, forKeyedSubscript: "randomBytes" as NSString)
        namespace.install(crypto, as: capabilityName.rawValue)
    }
}
