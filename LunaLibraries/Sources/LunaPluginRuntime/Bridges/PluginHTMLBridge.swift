//
//  PluginHTMLBridge.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaPluginKit
import SwiftSoup

/// The DOM members a plugin may use (§6.3).
///
/// It is a deliberately SMALL subset, because three backings have to agree on
/// it: SwiftSoup here, `DOMParser` in the Safari world, and `linkedom` in the
/// node harness. `LunaTests/Fixtures/Plugins/html-subset.spec.js` is the
/// specification; every backing runs the same file.
@objc protocol PluginHTMLNodeExports: JSExport {
    func querySelector(_ css: String) -> PluginHTMLNodeHandle?
    func querySelectorAll(_ css: String) -> [PluginHTMLNodeHandle]
    func getAttribute(_ name: String) -> String?
    func hasAttribute(_ name: String) -> Bool
    func matches(_ css: String) -> Bool
    func closest(_ css: String) -> PluginHTMLNodeHandle?
    /// Resolves an `href`/`src`-style attribute against `baseURI`.
    func absoluteURL(_ attribute: String) -> String?
    var textContent: String { get }
    var innerHTML: String { get }
    var outerHTML: String { get }
    var children: [PluginHTMLNodeHandle] { get }
    var parentElement: PluginHTMLNodeHandle? { get }
    var tagName: String { get }
    var attributes: [String: String] { get }
    var baseURI: String { get }
    var title: String { get }
    var documentElement: PluginHTMLNodeHandle? { get }
    var body: PluginHTMLNodeHandle? { get }
    var head: PluginHTMLNodeHandle? { get }
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

    public func querySelector(_ css: String) -> PluginHTMLNodeHandle? {
        guard let found = try? element.select(css).first() else { return nil }
        return PluginHTMLNodeHandle(found)
    }

    public func querySelectorAll(_ css: String) -> [PluginHTMLNodeHandle] {
        guard let found = try? element.select(css) else { return [] }
        return found.array().map(PluginHTMLNodeHandle.init)
    }

    public func matches(_ css: String) -> Bool {
        (try? element.iS(css)) ?? false
    }

    public func closest(_ css: String) -> PluginHTMLNodeHandle? {
        var current: Element? = element
        while let node = current {
            if (try? node.iS(css)) == true { return PluginHTMLNodeHandle(node) }
            current = node.parent()
        }
        return nil
    }

    // MARK: - Attributes

    public func getAttribute(_ name: String) -> String? {
        guard element.hasAttr(name) else { return nil }
        return try? element.attr(name)
    }

    public func hasAttribute(_ name: String) -> Bool {
        element.hasAttr(name)
    }

    public func absoluteURL(_ attribute: String) -> String? {
        guard element.hasAttr(attribute), let resolved = try? element.absUrl(attribute),
              !resolved.isEmpty
        else { return nil }
        return resolved
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

    public var parentElement: PluginHTMLNodeHandle? {
        element.parent().map(PluginHTMLNodeHandle.init)
    }

    /// Upper case, as the DOM reports it.
    public var tagName: String { element.tagName().uppercased() }

    public var baseURI: String { element.getBaseUri() }

    // MARK: - Document members

    public var title: String {
        guard let document = element as? Document else { return "" }
        return (try? document.title()) ?? ""
    }

    public var documentElement: PluginHTMLNodeHandle? {
        guard let document = element as? Document else { return nil }
        guard let root = try? document.select("html").first() else { return nil }
        return PluginHTMLNodeHandle(root)
    }

    public var body: PluginHTMLNodeHandle? {
        guard let document = element as? Document, let body = document.body() else { return nil }
        return PluginHTMLNodeHandle(body)
    }

    public var head: PluginHTMLNodeHandle? {
        guard let document = element as? Document, let head = document.head() else { return nil }
        return PluginHTMLNodeHandle(head)
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

    public init() {}

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let html = namespace.makeNamespaceObject()

        let parse: @convention(block) (String?, String?) -> PluginHTMLNodeHandle? = { source, base in
            let context = JSContext.current() ?? outerContext
            guard let source else {
                PluginBridgeValue.raise("luna.html.parse needs HTML text", in: context)
                return nil
            }
            let baseURI = (base?.isEmpty ?? true) ? "" : base!
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

        let jsonScripts: @convention(block) (JSValue?, String?) -> [Any] = { value, type in
            guard let handle = value?.toObjectOf(PluginHTMLNodeHandle.self)
                as? PluginHTMLNodeHandle
            else { return [] }
            return PluginHTMLBridge.jsonScripts(in: handle.element, type: type)
        }

        html.setObject(parse, forKeyedSubscript: "parse" as NSString)
        html.setObject(text, forKeyedSubscript: "text" as NSString)
        html.setObject(jsonScripts, forKeyedSubscript: "jsonScripts" as NSString)
        namespace.install(html, as: capabilityName.rawValue)
    }

    /// The parsed bodies of the document's JSON script tags. Bad JSON is
    /// skipped: one malformed block on a page must not cost a plugin the rest.
    static func jsonScripts(in element: Element, type: String?) -> [Any] {
        let selector = type.map { "script[type=\($0)]" }
            ?? "script[type=application/ld+json], script[type=application/json]"
        guard let scripts = try? element.select(selector) else { return [] }
        return scripts.array().compactMap { script in
            guard let source = try? script.html(), !source.isEmpty else { return nil }
            return try? JSONSerialization.jsonObject(
                with: Data(source.utf8), options: [.fragmentsAllowed])
        }
    }
}
