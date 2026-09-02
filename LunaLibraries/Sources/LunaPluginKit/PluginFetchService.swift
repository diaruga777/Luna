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
    /// state, an ephemeral jar gets the logged-out page, and none at all is how
    /// a crawler identity asks. A plugin that wants the session the browser
    /// modal earned reads `cookieHeader` off the browser result and sets the
    /// header itself.
    public enum CookiePolicy: String, Equatable, Sendable {
        case shared, ephemeral, none
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
    /// Whose scratch directory an `as: "file"` response is written into, and
    /// whose in-flight hooks the byte-progress touch keeps alive. The service is
    /// shared by every plugin, so both ride the REQUEST rather than a property
    /// two hooks could race over.
    public let pluginID: String
    /// Names the scratch generation an `as: "file"` response is written into.
    public let invocationID: String

    public init(
        url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
        cookies: CookiePolicy = .shared, redirect: RedirectPolicy = .follow,
        maxBytes: Int = WebFetchConstants.maxBytes, timeout: TimeInterval = 20,
        responseForm: ResponseForm = .text, invocationID: String = "shared",
        pluginID: String = "shared"
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
        self.pluginID = pluginID
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

    /// Writes the body when a request asked for `as: "file"`.
    public var fileWriter: PluginFileWriting?
    /// Touched on every chunk, so a long download keeps the ingest watchdog
    /// alive.
    public var idle: PluginIdleTouching?

    private let delegateQueue = OperationQueue()
    /// One session per cookie policy, made on first use. A session is expensive
    /// and a policy is one of three.
    private var sessions: [PluginFetchRequest.CookiePolicy: URLSession] = [:]
    /// Keyed by the task OBJECT: `taskIdentifier` is unique within one session,
    /// and three sessions each hand out a task 1.
    private var transfers: [ObjectIdentifier: Transfer] = [:]
    private let lock = NSLock()

    /// Protocol classes every session gets, ahead of the system's. A test serves
    /// its own fixtures this way; `URLProtocol.registerClass` reaches only the
    /// shared session, never one built from a configuration.
    private let protocolClasses: [AnyClass]
    /// The sessions' delegate. A `URLSession` retains its delegate until it is
    /// invalidated, so the service cannot be the delegate itself: the cycle
    /// would keep every replaced service, its sessions and its delegate queue
    /// alive for the life of the process.
    private let delegateProxy = PluginFetchSessionDelegate()

    public init(protocolClasses: [AnyClass] = []) {
        self.protocolClasses = protocolClasses
        super.init()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateProxy.service = self
    }

    deinit {
        for session in sessions.values { session.finishTasksAndInvalidate() }
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
            invocationID: request.invocationID, pluginID: request.pluginID)
        start(probe) { [weak self] outcome in
            guard let self else { return }
            let landing = (try? outcome.get()).flatMap { URL(string: $0.finalURL) } ?? request.url
            let follow = PluginFetchRequest(
                url: landing, method: request.method, headers: request.headers,
                body: request.body, cookies: request.cookies, redirect: .follow,
                maxBytes: request.maxBytes, timeout: request.timeout,
                responseForm: request.responseForm, invocationID: request.invocationID,
                pluginID: request.pluginID)
            self.start(follow, completion: completion)
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
        transfers[ObjectIdentifier(task)] = Transfer(request: request, completion: completion)
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
        case .ephemeral:
            configuration = .ephemeral
        case .none:
            configuration = .ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpCookieStorage = nil
        }
        configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        let session = URLSession(
            configuration: configuration, delegate: delegateProxy, delegateQueue: delegateQueue)
        sessions[policy] = session
        return session
    }

    private func transfer(_ task: URLSessionTask) -> Transfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers[ObjectIdentifier(task)]
    }

    private func finishTransfer(_ task: URLSessionTask) -> Transfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers.removeValue(forKey: ObjectIdentifier(task))
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

extension PluginFetchService {

    fileprivate func urlSession(
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

    fileprivate func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        transfer(dataTask)?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    fileprivate func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        guard let transfer = transfer(dataTask) else { return }
        // Progress, not a wall clock: a large response that keeps arriving keeps
        // both watchdogs alive.
        IdleTimeLimit.touch()
        idle?.touchIdle(pluginID: transfer.request.pluginID)
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

    fileprivate func urlSession(
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
            do {
                file = try writer.writeFile(
                    transfer.body, suggestedName: finalURL.lastPathComponent,
                    mime: headers.first { $0.key.lowercased() == "content-type" }?.value,
                    pluginID: transfer.request.pluginID,
                    generation: transfer.request.invocationID)
            } catch {
                transfer.completion(.failure(PluginFetchError(
                    "the response could not be written to a file: "
                        + error.localizedDescription,
                    code: "write-failed")))
                return
            }
        }
        transfer.completion(.success(PluginFetchResponse(
            status: response.statusCode, finalURL: finalURL.absoluteString, headers: headers,
            body: transfer.body, truncated: transfer.truncated,
            redirected: transfer.redirected, file: file)))
    }
}

/// The sessions' delegate, holding the service weakly.
///
/// `URLSession` retains its delegate until it is invalidated, so a service that
/// was its own delegate could never be released — and
/// `PluginPlatformComposition.install` builds a fresh service on every run.
private final class PluginFetchSessionDelegate: NSObject, URLSessionDataDelegate {

    weak var service: PluginFetchService?

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let service else {
            completionHandler(request)
            return
        }
        service.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: request,
            completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let service else {
            completionHandler(.allow)
            return
        }
        service.urlSession(
            session, dataTask: dataTask, didReceive: response,
            completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        service?.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        service?.urlSession(session, task: task, didCompleteWithError: error)
    }
}
