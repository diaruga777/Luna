//
//  PluginFetchService.swift
//  LunaPluginKit
//

import Foundation
import LunaModels
import LunaURLClassification

/// What a plugin asked the network for (§6.2).
public struct PluginFetchRequest: Equatable, Sendable {

    /// Whose cookie jar a request uses. The shared jar carries a site's consent
    /// state, an ephemeral jar gets the logged-out page, none at all is how a
    /// crawler identity asks, and `browser` is what the lock modal earned.
    public enum CookiePolicy: String, Equatable, Sendable {
        case shared, ephemeral, none, browser
    }

    /// What happens at a 3xx.
    public enum RedirectPolicy: String, Equatable, Sendable {
        case follow
        /// Stop at the redirect and report it — how a resolver reads a
        /// `Location` without paying for the body.
        case manual
        /// HEAD first, then GET what the HEAD landed on.
        case headThenGet
    }

    /// How the plugin wants the body back.
    public enum ResponseForm: String, Equatable, Sendable {
        case text, base64, file
    }

    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    public let cookies: CookiePolicy
    public let redirect: RedirectPolicy
    /// The response is cut here and reported truncated.
    public let maxBytes: Int
    /// Idle seconds, not total: `URLSession` restarts it on every byte, so a
    /// slow large download is not a timeout and a stalled one is.
    public let timeout: TimeInterval
    public let responseForm: ResponseForm
    /// Names the scratch directory an `as: "file"` response is written into. The
    /// service is shared by every plugin, so the invocation rides the REQUEST
    /// rather than a property two hooks could race over.
    public let invocationID: String

    public init(
        url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
        cookies: CookiePolicy = .shared, redirect: RedirectPolicy = .follow,
        maxBytes: Int = WebFetchConstants.maxBytes, timeout: TimeInterval = 20,
        responseForm: ResponseForm = .text, invocationID: String = "shared"
    ) {
        self.url = url
        self.method = method.uppercased()
        self.headers = headers
        self.body = body
        self.cookies = cookies
        self.redirect = redirect
        self.maxBytes = max(1, min(maxBytes, WebFetchConstants.maxBytes))
        self.timeout = timeout
        self.responseForm = responseForm
        self.invocationID = invocationID
    }
}

/// What came back.
public struct PluginFetchResponse: Equatable, Sendable {
    public let status: Int
    /// Where the request ENDED. A plugin reads this rather than assuming its
    /// request URL survived.
    public let finalURL: String
    public let headers: [String: String]
    public let body: Data
    /// True when the body hit `maxBytes` and was cut.
    public let truncated: Bool
    public let redirected: Bool
    /// Set when the request asked for `as: "file"`.
    public let file: PluginFileDescriptor?

    public init(
        status: Int, finalURL: String, headers: [String: String], body: Data,
        truncated: Bool, redirected: Bool, file: PluginFileDescriptor? = nil
    ) {
        self.status = status
        self.finalURL = finalURL
        self.headers = headers
        self.body = body
        self.truncated = truncated
        self.redirected = redirected
        self.file = file
    }

    public var isOK: Bool { (200..<300).contains(status) }
}

public struct PluginFetchError: Error, Equatable {
    public let message: String
    /// The `LunaError` code the plugin sees.
    public let code: String

    public init(_ message: String, code: String = "fetch-failed") {
        self.message = message
        self.code = code
    }
}

/// Hands over the cookies a `WKWebsiteDataStore` holds for a URL.
///
/// WebKit is not available to `LunaPluginKit` — the Safari appex links it and
/// carries no UIKit tier — so `cookies: "browser"` is served through a witness
/// the app installs. With no witness the request is refused, rather than
/// quietly downgraded to the shared jar: a plugin asking for the browser's
/// cookies is asking for the session the lock modal earned.
public protocol PluginBrowserCookieProviding: AnyObject {
    func browserCookies(for url: URL, completion: @escaping ([HTTPCookie]) -> Void)
}

/// The network leg of `luna.fetch`, as a witness a caller installs.
public protocol PluginURLFetching: AnyObject {
    func fetch(
        _ request: PluginFetchRequest,
        completion: @escaping (Result<PluginFetchResponse, PluginFetchError>) -> Void)
}

/// `luna.fetch` over `URLSession`.
///
/// It sits directly on `URLSession` rather than on `ArticleFetcher`, and owns
/// the four things a plugin must not have to re-learn: the same byte ceiling
/// the article path uses, the live-network policy, an idle-based timeout fed by
/// byte progress, and a per-request cookie jar. Redirects are answered by the
/// session delegate, so `manual` really stops at the 3xx instead of reporting
/// the last hop of a follow.
public final class PluginFetchService: NSObject, PluginURLFetching {

    /// Serves `cookies: "browser"`. Installed by the app; nil everywhere else.
    public var browserCookies: PluginBrowserCookieProviding?
    /// Writes the body when a request asked for `as: "file"`.
    public var fileWriter: PluginFileWriting?
    /// Touched on every chunk, so a long download keeps the ingest watchdog
    /// alive.
    public var idle: PluginIdleTouching?

    private let delegateQueue = OperationQueue()
    /// One session per cookie policy, made on first use. A session is expensive
    /// and a policy is one of three (`browser` reuses the ephemeral jar and
    /// carries its cookies in a header).
    private var sessions: [PluginFetchRequest.CookiePolicy: URLSession] = [:]
    private var transfers: [Int: Transfer] = [:]
    private let lock = NSLock()

    /// Protocol classes every session gets, ahead of the system's. A test serves
    /// its own fixtures this way; `URLProtocol.registerClass` reaches only the
    /// shared session, never one built from a configuration.
    private let protocolClasses: [AnyClass]
    public init(protocolClasses: [AnyClass] = []) {
        self.protocolClasses = protocolClasses
        super.init()
        delegateQueue.maxConcurrentOperationCount = 1
    }

    public func fetch(
        _ request: PluginFetchRequest,
        completion: @escaping (Result<PluginFetchResponse, PluginFetchError>) -> Void
    ) {
        do {
            try LiveNetworkPolicy.check(request.url, context: "luna.fetch")
        } catch {
            completion(.failure(PluginFetchError("\(error)", code: "network-refused")))
            return
        }
        guard request.cookies != .browser else {
            resolveBrowserCookies(request, completion: completion)
            return
        }
        guard request.redirect == .headThenGet else {
            start(request, completion: completion)
            return
        }
        // Learn where the URL lands without reading its body, then read what is
        // actually there.
        let probe = PluginFetchRequest(
            url: request.url, method: "HEAD", headers: request.headers, body: nil,
            cookies: request.cookies, redirect: .follow, maxBytes: request.maxBytes,
            timeout: request.timeout, responseForm: request.responseForm,
            invocationID: request.invocationID)
        start(probe) { [weak self] outcome in
            guard let self else { return }
            let landing = (try? outcome.get()).flatMap { URL(string: $0.finalURL) } ?? request.url
            let follow = PluginFetchRequest(
                url: landing, method: request.method, headers: request.headers,
                body: request.body, cookies: request.cookies, redirect: .follow,
                maxBytes: request.maxBytes, timeout: request.timeout,
                responseForm: request.responseForm, invocationID: request.invocationID)
            self.start(follow, completion: completion)
        }
    }

    /// Turns `cookies: "browser"` into a `Cookie` header over the ephemeral jar,
    /// so the browser's session is used without the shared jar being written.
    private func resolveBrowserCookies(
        _ request: PluginFetchRequest,
        completion: @escaping (Result<PluginFetchResponse, PluginFetchError>) -> Void
    ) {
        guard let provider = browserCookies else {
            completion(.failure(PluginFetchError(
                "cookies: \"browser\" needs the app's web view, which this process has not",
                code: "unavailable-here")))
            return
        }
        provider.browserCookies(for: request.url) { [weak self] cookies in
            guard let self else { return }
            var headers = request.headers
            let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            if !header.isEmpty { headers["Cookie"] = header }
            self.start(PluginFetchRequest(
                url: request.url, method: request.method, headers: headers, body: request.body,
                cookies: .none, redirect: request.redirect, maxBytes: request.maxBytes,
                timeout: request.timeout, responseForm: request.responseForm,
                invocationID: request.invocationID),
                completion: completion)
        }
    }

    // MARK: - One transfer

    private func start(
        _ request: PluginFetchRequest,
        completion: @escaping (Result<PluginFetchResponse, PluginFetchError>) -> Void
    ) {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = request.cookies == .shared
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if urlRequest.value(forHTTPHeaderField: "User-Agent") == nil {
            urlRequest.setValue(
                WebFetchConstants.safariUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let session = self.session(for: request.cookies)
        let task = session.dataTask(with: urlRequest)
        lock.lock()
        transfers[task.taskIdentifier] = Transfer(request: request, completion: completion)
        lock.unlock()
        task.resume()
    }

    private func session(for policy: PluginFetchRequest.CookiePolicy) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[policy] { return existing }
        let configuration: URLSessionConfiguration
        switch policy {
        case .shared:
            configuration = .default
        case .ephemeral, .browser:
            configuration = .ephemeral
        case .none:
            configuration = .ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpCookieStorage = nil
        }
        configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        let session = URLSession(
            configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        sessions[policy] = session
        return session
    }

    private func transfer(_ task: URLSessionTask) -> Transfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers[task.taskIdentifier]
    }

    private func finishTransfer(_ task: URLSessionTask) -> Transfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers.removeValue(forKey: task.taskIdentifier)
    }

    /// One request's accumulating state.
    private final class Transfer {
        let request: PluginFetchRequest
        let completion: (Result<PluginFetchResponse, PluginFetchError>) -> Void
        var body = Data()
        var response: HTTPURLResponse?
        var truncated = false
        var redirected = false
        /// Set when the delegate stopped a redirect, so the 3xx itself is what
        /// the plugin gets.
        var haltedRedirect: HTTPURLResponse?

        init(
            request: PluginFetchRequest,
            completion: @escaping (Result<PluginFetchResponse, PluginFetchError>) -> Void
        ) {
            self.request = request
            self.completion = completion
        }
    }
}

extension PluginFetchService: URLSessionDataDelegate {

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let transfer = transfer(task) else {
            completionHandler(request)
            return
        }
        switch transfer.request.redirect {
        case .follow, .headThenGet:
            transfer.redirected = true
            completionHandler(request)
        case .manual:
            transfer.haltedRedirect = response
            completionHandler(nil)
        }
    }

    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        transfer(dataTask)?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        guard let transfer = transfer(dataTask) else { return }
        // Progress, not a wall clock: a large response that keeps arriving keeps
        // both watchdogs alive.
        IdleTimeLimit.touch()
        idle?.touchIdle()
        let room = transfer.request.maxBytes - transfer.body.count
        guard room > 0 else {
            transfer.truncated = true
            dataTask.cancel()
            return
        }
        if data.count > room {
            transfer.body.append(data.prefix(room))
            transfer.truncated = true
            dataTask.cancel()
        } else {
            transfer.body.append(data)
        }
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard let transfer = finishTransfer(task) else { return }
        let response = transfer.haltedRedirect ?? transfer.response
            ?? task.response as? HTTPURLResponse
        // A cancel from the size cap is a success with a cut body, not a failure.
        if let error, !(transfer.truncated && (error as NSError).code == NSURLErrorCancelled) {
            transfer.completion(.failure(PluginFetchError(error.localizedDescription)))
            return
        }
        guard let response else {
            transfer.completion(.failure(PluginFetchError("the server sent no HTTP response")))
            return
        }
        let finalURL = transfer.haltedRedirect?.url
            ?? task.currentRequest?.url
            ?? transfer.request.url
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            headers[name] = value
        }
        var file: PluginFileDescriptor?
        if transfer.request.responseForm == .file {
            guard let writer = fileWriter else {
                transfer.completion(.failure(PluginFetchError(
                    "as: \"file\" needs the \"files\" capability", code: "unavailable-here")))
                return
            }
            file = try? writer.writeFile(
                transfer.body, suggestedName: finalURL.lastPathComponent,
                mime: headers.first { $0.key.lowercased() == "content-type" }?.value,
                invocationID: transfer.request.invocationID)
        }
        transfer.completion(.success(PluginFetchResponse(
            status: response.statusCode, finalURL: finalURL.absoluteString, headers: headers,
            body: transfer.body, truncated: transfer.truncated,
            redirected: transfer.redirected, file: file)))
    }
}
