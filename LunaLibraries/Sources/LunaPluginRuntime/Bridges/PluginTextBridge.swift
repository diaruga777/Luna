//
//  PluginTextBridge.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaPluginKit

/// `luna.text` — three pure string helpers a generated extractor otherwise
/// writes by hand and gets wrong.
///
/// It is NOT a capability of its own: `PluginHTMLBridge` installs it, and
/// `PluginCapabilityName.html.companionNamespaces` is what tells the grant
/// check that `luna.text` beside `luna.html` is expected rather than a bridge
/// writing where it should not. Nothing here reaches the network, the store or
/// the file system, so there is no grant a user could meaningfully give or
/// withhold for it.
public enum PluginTextBridge {

    /// The member names installed at `luna.text`. `PluginAPISurfaceTests`
    /// builds the expected `.d.ts` surface from it.
    public static let installedMembers = ["price", "date", "clean"]

    /// The `luna.<name>` this bridge writes.
    public static let namespaceName = "text"

    public static func install(into namespace: PluginCapabilityNamespace) {
        let text = namespace.makeNamespaceObject()

        /// `{ amount, currency? }`, or null when the string holds no number.
        let price: @convention(block) (JSValue?) -> Any = { _ in
            PluginBridgeValue.raise("Bundle plugin-owned price parsing; luna.text.price is retired", in: namespace.context)
            return NSNull()
        }
        let date: @convention(block) (JSValue?) -> Any = { _ in
            PluginBridgeValue.raise("Bundle plugin-owned date parsing; luna.text.date is retired", in: namespace.context)
            return NSNull()
        }

        let clean: @convention(block) (JSValue?) -> String = { value in
            PluginTextParsing.clean(PluginBridgeValue.optionalString(value) ?? "")
        }

        text.setObject(price, forKeyedSubscript: "price" as NSString)
        text.setObject(date, forKeyedSubscript: "date" as NSString)
        text.setObject(clean, forKeyedSubscript: "clean" as NSString)
        namespace.install(text, as: namespaceName)
    }
}
