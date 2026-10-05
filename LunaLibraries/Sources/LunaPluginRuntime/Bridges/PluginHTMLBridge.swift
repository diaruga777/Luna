//
//  PluginHTMLBridge.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaModels
import LunaPluginKit
import SwiftSoup

/// The DOM members a plugin may use (§6.3).
///
/// It is a deliberately SMALL subset, because three backings have to agree on
/// it: SwiftSoup here, `DOMParser` in the Safari world, and `linkedom` in the
/// node harness. `LunaTests/Fixtures/Plugins/html-subset.spec.js` is the
/// specification; every backing runs the same file.
/// Nothing is `null`, never `undefined`. A JSExport method that answers a nil
/// Swift object bridges to `undefined`, while the Safari world's `DOMParser`
/// answers `null` — so a plugin's `=== null` would be true in one backing and
/// false in the other. Every member that may find nothing therefore answers a
/// `JSValue` built in the caller's own context.
@objc protocol PluginHTMLNodeExports: JSExport {
    func querySelector(_ css: String) -> JSValue?
    func querySelectorAll(_ css: String) -> [PluginHTMLNodeHandle]
    func getAttribute(_ name: String) -> JSValue?
    func hasAttribute(_ name: String) -> Bool
    func matches(_ css: String) -> Bool
    func closest(_ css: String) -> JSValue?
    /// Resolves an `href`/`src`-style attribute against `baseURI`.
    func absoluteURL(_ attribute: String) -> JSValue?
    var textContent: String { get }
    var innerHTML: String { get }
    var outerHTML: String { get }
    var children: [PluginHTMLNodeHandle] { get }
    var parentElement: JSValue? { get }
    var tagName: String { get }
    var attributes: [String: String] { get }
    var baseURI: String { get }
    var title: String { get }
    var documentElement: JSValue? { get }
    var body: JSValue? { get }
    var head: JSValue? { get }
}

/// One node a plugin holds. It wraps a SwiftSoup element; the document is the
/// same class, because a `Document` IS an `Element` and the subset's
/// document-only members read as empty on any other node.
@objc public final class PluginHTMLNodeHandle: NSObject, PluginHTMLNodeExports {

    let element: Element

    init(_ element: Element) {
        self.element = element
    }

    // MARK: - Queries

    public func querySelector(_ css: String) -> JSValue? {
        Self.value((try? element.select(css).array().first { $0 !== element })
            .flatMap { $0 }.map(PluginHTMLNodeHandle.init))
    }

    public func querySelectorAll(_ css: String) -> [PluginHTMLNodeHandle] {
        guard let found = try? element.select(css) else { return [] }
        return found.array().filter { $0 !== element }.map(PluginHTMLNodeHandle.init)
    }

    public func matches(_ css: String) -> Bool {
        (try? element.iS(css)) ?? false
    }

    public func closest(_ css: String) -> JSValue? {
        var current: Element? = element
        while let node = current {
            if (try? node.iS(css)) == true { return Self.value(PluginHTMLNodeHandle(node)) }
            current = node.parent()
        }
        return Self.value(nil)
    }

    // MARK: - Attributes

    public func getAttribute(_ name: String) -> JSValue? {
        guard element.hasAttr(name) else { return Self.value(nil) }
        return Self.value((try? element.attr(name)) ?? "")
    }

    public func hasAttribute(_ name: String) -> Bool {
        element.hasAttr(name)
    }

    public func absoluteURL(_ attribute: String) -> JSValue? {
        guard element.hasAttr(attribute), let resolved = try? element.absUrl(attribute),
              !resolved.isEmpty
        else { return Self.value(nil) }
        return Self.value(resolved)
    }

    public var attributes: [String: String] {
        guard let attributes = element.getAttributes() else { return [:] }
        var result: [String: String] = [:]
        for attribute in attributes {
            result[attribute.getKey()] = attribute.getValue()
        }
        return result
    }

    // MARK: - Content

    public var textContent: String { (try? element.text()) ?? "" }

    public var innerHTML: String { (try? element.html()) ?? "" }

    public var outerHTML: String { (try? element.outerHtml()) ?? "" }

    public var children: [PluginHTMLNodeHandle] {
        element.children().array().map(PluginHTMLNodeHandle.init)
    }

    public var parentElement: JSValue? {
        Self.value(element.parent().map(PluginHTMLNodeHandle.init))
    }

    /// Upper case, as the DOM reports it.
    public var tagName: String { element.tagName().uppercased() }

    public var baseURI: String { element.getBaseUri() }

    // MARK: - Document members

    public var title: String {
        guard let document = element as? Document else { return "" }
        return (try? document.title()) ?? ""
    }

    public var documentElement: JSValue? {
        guard let document = element as? Document,
              let root = try? document.select("html").first()
        else { return Self.value(nil) }
        return Self.value(PluginHTMLNodeHandle(root))
    }

    public var body: JSValue? {
        guard let document = element as? Document, let body = document.body() else {
            return Self.value(nil)
        }
        return Self.value(PluginHTMLNodeHandle(body))
    }

    public var head: JSValue? {
        guard let document = element as? Document, let head = document.head() else {
            return Self.value(nil)
        }
        return Self.value(PluginHTMLNodeHandle(head))
    }

    /// A value in the CALLING context, so nothing reads as `undefined`.
    ///
    /// A bare `JSContext()` would mint a whole new virtual machine, and the
    /// value it returned would belong to a machine the plugin's context cannot
    /// read. A member read outside a JS call answers `undefined` instead.
    private static func value(_ object: Any?) -> JSValue? {
        guard let context = JSContext.current() else { return nil }
        guard let object else { return JSValue(nullIn: context) }
        return JSValue(object: object, in: context) ?? JSValue(nullIn: context)
    }
}

/// `luna.html` over SwiftSoup (§6.3).
///
/// A parsed document is a native handle, so the whole tree stays in Swift and
/// only the nodes a plugin actually touches cross the bridge. The handles a
/// hook made are released when its context drops them, which is why the
/// namespace holds no document of its own.
public final class PluginHTMLBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.html

    /// `luna.html.article` answers a Promise, so this bridge settles on the
    /// runtime's own queue like every other asynchronous member.
    private let scheduler: PluginCallbackScheduling

    public init(scheduler: PluginCallbackScheduling) {
        self.scheduler = scheduler
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let pluginID = namespace.pluginID
        let generationID = namespace.target.generationID
        let scheduler = self.scheduler
        let html = namespace.makeNamespaceObject()

        let parse: @convention(block) (String?, JSValue?) -> PluginHTMLNodeHandle? = { source, base in
            let context = JSContext.current() ?? outerContext
            guard let source else {
                PluginBridgeValue.raise("luna.html.parse needs HTML text", in: context)
                return nil
            }
            let baseURI = PluginBridgeValue.optionalString(base) ?? ""
            guard let document = try? SwiftSoup.parse(source, baseURI) else {
                PluginBridgeValue.raise("luna.html.parse could not read that HTML", in: context)
                return nil
            }
            return PluginHTMLNodeHandle(document)
        }

        /// Entities decoded and tags stripped, for a title or a caption a page
        /// wrote as escaped markup.
        let text: @convention(block) (String?) -> String = { source in
            guard let source, let document = try? SwiftSoup.parse(source) else { return "" }
            return (try? document.text()) ?? ""
        }

        let jsonScripts: @convention(block) (JSValue?, JSValue?) -> [Any] = { value, type in
            guard let handle = value?.toObject() as? PluginHTMLNodeHandle else { return [] }
            return PluginHTMLBridge.jsonScripts(
                in: handle.element, type: PluginBridgeValue.optionalString(type))
        }

        let jsonLD: @convention(block) (JSValue?) -> [Any] = { value in
            guard let handle = value?.toObject() as? PluginHTMLNodeHandle else { return [] }
            return PluginHTMLMetadata.jsonLD(in: handle.element)
        }

        let meta: @convention(block) (JSValue?) -> JSValue? = { _ in
            PluginBridgeValue.raise("Bundle plugin-owned metadata helpers; luna.html.meta is retired", in: JSContext.current() ?? outerContext)
            return nil
        }
        let article: @convention(block) (JSValue?, JSValue?) -> JSValue? = { _, _ in
            PluginBridgeValue.raise("Bundle plugin-owned article extraction; luna.html.article is retired", in: JSContext.current() ?? outerContext)
            return nil
        }

        html.setObject(parse, forKeyedSubscript: "parse" as NSString)
        html.setObject(text, forKeyedSubscript: "text" as NSString)
        html.setObject(jsonScripts, forKeyedSubscript: "jsonScripts" as NSString)
        html.setObject(jsonLD, forKeyedSubscript: "jsonLD" as NSString)
        html.setObject(meta, forKeyedSubscript: "meta" as NSString)
        html.setObject(article, forKeyedSubscript: "article" as NSString)
        namespace.install(html, as: capabilityName.rawValue)
        // `luna.text` has no capability of its own: it rides on `html`
        // (`PluginCapabilityName.companionNamespaces`).
        PluginTextBridge.install(into: namespace)
    }

    /// The member names this bridge installs at `luna.html`.
    /// `PluginAPISurfaceTests` builds the expected `.d.ts` surface from it, so
    /// a member added here without its typing fails the build.
    public static let installedMembers = ["parse", "text", "jsonScripts", "jsonLD", "meta", "article"]

    /// The parsed bodies of the document's JSON script tags. Bad JSON is
    /// skipped: one malformed block on a page must not cost a plugin the rest.
    static func jsonScripts(in element: Element, type: String?) -> [Any] {
        let selector = type.map { "script[type=\($0)]" }
            ?? "script[type=application/ld+json], script[type=application/json]"
        guard let scripts = try? element.select(selector) else { return [] }
        return scripts.array().compactMap { script in
            // A script's body is a data node, so `data()` is its text; `html()`
            // escapes it.
            let source = script.data().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { return nil }
            return try? JSONSerialization.jsonObject(
                with: Data(source.utf8), options: [.fragmentsAllowed])
        }
    }
}
