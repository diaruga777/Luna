//
//  PluginBrowserPage.swift
//  LunaPluginUI
//

import LunaArchiveReader
import UIKit
import WebKit

/// The live page a plugin's browser step drives.
///
/// A seam rather than a bare `WKWebView`: the stage machine above it — cover,
/// probe, capture, timeout — is the part worth testing, and a test that had to
/// stand up a WebContent process would be testing WebKit instead.
@MainActor
public protocol PluginBrowserPageDriving: AnyObject {
    /// The view the modal mounts under its cover.
    var pageView: UIView { get }
    /// Where the page has actually got to, for the Safari escape.
    var currentURL: URL? { get }
    func load(_ request: PluginBrowserRequest)
    /// Runs the plugin's `detect` source and answers what it evaluated to.
    func probe(_ source: String, completion: @escaping (String?) -> Void)
    /// Reads the finished page: its HTML, final URL, title and cookies.
    func capture(completion: @escaping (PluginBrowserResult?) -> Void)
    func stopLoading()
}

/// Builds the live page one browser step drives.
///
/// The flow that presents a step does not build its own web view: the page is
/// where the network is, and a test of the flow has no business starting a
/// WebContent process.
@MainActor
public protocol PluginBrowserPageMaking: AnyObject {
    func makePage(for request: PluginBrowserRequest) -> any PluginBrowserPageDriving
}

/// The shipped maker.
@MainActor
public final class WebKitPluginBrowserPageMaker: PluginBrowserPageMaking {
    public init() {}

    public func makePage(for request: PluginBrowserRequest) -> any PluginBrowserPageDriving {
        WebKitPluginBrowserPage(cookies: request.cookies, userAgent: request.userAgent)
    }
}

/// The WebKit answer: one always-live web view under the modal's cover.
///
/// It presents the device-matched Safari User-Agent for the same reason the
/// archive unlock does — a UA that disagrees with the OS is what a bot check
/// reads as automation — and runs against the persistent cookie jar unless the
/// request asked for an ephemeral one.
@MainActor
public final class WebKitPluginBrowserPage: NSObject, PluginBrowserPageDriving {

    private let webView: WKWebView

    public init(cookies: PluginBrowserRequest.CookieStore, userAgent: String?) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = cookies == .ephemeral
            ? .nonPersistent() : .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent =
            (userAgent.map { $0 == PluginBrowserRequest.deviceSafariUserAgent } ?? true)
            ? DeviceSafariUserAgent.current
            : userAgent
        super.init()
    }

    public var pageView: UIView { webView }

    public var currentURL: URL? { webView.url }

    public func load(_ request: PluginBrowserRequest) {
        var urlRequest = URLRequest(url: request.url)
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        webView.load(urlRequest)
    }

    public func probe(_ source: String, completion: @escaping (String?) -> Void) {
        webView.evaluateProbe(source, completion: completion)
    }

    public func capture(completion: @escaping (PluginBrowserResult?) -> Void) {
        let finalURL = webView.url?.absoluteString ?? ""
        let title = webView.title ?? ""
        let host = webView.url?.host?.lowercased()
        webView.evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
            let html = value as? String ?? ""
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { jar in
                let matching = jar.filter { Self.cookie($0, matches: host) }
                let cookies = matching.map {
                    PluginBrowserResult.Cookie(
                        name: $0.name, value: $0.value, domain: $0.domain)
                }
                let header = matching
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                completion(PluginBrowserResult(
                    url: finalURL, html: html, title: title,
                    cookieHeader: header, cookies: cookies))
            }
        }
    }

    public func stopLoading() {
        webView.stopLoading()
    }

    /// A cookie belongs to the page's domain when it names that host exactly or
    /// is a dot-prefixed parent of it, which is the rule a browser sends by.
    static func cookie(_ cookie: HTTPCookie, matches host: String?) -> Bool {
        guard let host else { return false }
        let domain = cookie.domain.lowercased()
        if domain == host { return true }
        guard domain.hasPrefix(".") else { return false }
        return host.hasSuffix(domain) || host == String(domain.dropFirst())
    }
}
