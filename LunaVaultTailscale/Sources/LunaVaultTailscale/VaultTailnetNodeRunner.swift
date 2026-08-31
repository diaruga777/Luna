import Foundation
import LunaVaultBackend
import TailscaleKit
import os

public struct VaultTailnetConfiguration: Sendable {
    public let stateDirectory: URL
    public let hostName: String
    public let controlURL: String
    public let ephemeral: Bool

    public init(stateDirectory: URL, hostName: String,
                controlURL: String = kDefaultControlURL, ephemeral: Bool = false) {
        self.stateDirectory = stateDirectory
        self.hostName = hostName
        self.controlURL = controlURL
        self.ephemeral = ephemeral
    }
}

public enum VaultTailnetError: Error, Equatable {
    /// The node has no usable login; the caller must run the interactive
    /// web-auth flow before the tailnet is dialable.
    case needsLogin
    case timedOut
    case unavailable(String)
}

/// Owns the embedded tsnet node. The node starts lazily on first use so an
/// app launch never pays for a tailnet the user has not configured. All
/// blocking libtailscale calls run on a dispatch queue, never on the actor's
/// executor.
public actor VaultTailnetNodeRunner {
    private let configuration: VaultTailnetConfiguration
    private let logger: LogSink?
    private var node: TailscaleNode?
    private let blockingQueue = DispatchQueue(label: "com.hsanabria.luna.vault.tailnet",
                                              qos: .userInitiated, attributes: .concurrent)
    private static let upTimeout: TimeInterval = 45

    public init(configuration: VaultTailnetConfiguration, logger: LogSink? = nil) {
        self.configuration = configuration
        self.logger = logger ?? VaultTailnetLogSink()
    }

    /// True when the node has stored control-plane state from a prior login.
    /// Used to decide whether dialing is worth starting the node at all.
    public nonisolated var hasPersistedState: Bool {
        let contents = try? FileManager.default.contentsOfDirectory(
            atPath: configuration.stateDirectory.path)
        return !(contents ?? []).isEmpty
    }

    private func runningNode() throws -> TailscaleNode {
        if let node { return node }
        try FileManager.default.createDirectory(at: configuration.stateDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let config = Configuration(hostName: configuration.hostName,
                                   path: configuration.stateDirectory.path,
                                   authKey: nil,
                                   controlURL: configuration.controlURL,
                                   ephemeral: configuration.ephemeral)
        let value = try TailscaleNode(config: config, logger: logger)
        node = value
        return value
    }

    public func shutDown() async {
        guard let node else { return }
        self.node = nil
        try? await node.close()
    }

    // MARK: - Status

    public func statusSummary() async -> VaultTailnetStatusSummary? {
        guard node != nil || hasPersistedState else { return nil }
        guard let node = try? runningNode(),
              let data = try? await node.statusJSON(),
              let status = try? JSONDecoder().decode(IpnState.Status.self, from: data) else {
            return nil
        }
        return Self.summary(from: status)
    }

    static func summary(from status: IpnState.Status) -> VaultTailnetStatusSummary {
        let ips = status.TailscaleIPs ?? []
        return VaultTailnetStatusSummary(
            backend: VaultTailnetStatusSummary.Backend(backendState: status.BackendState),
            dnsName: status.SelfStatus.map { name in
                name.DNSName.hasSuffix(".") ? String(name.DNSName.dropLast()) : name.DNSName
            },
            tailnetName: status.CurrentTailnet?.Name,
            ipv4: ips.first { $0.contains(".") },
            ipv6: ips.first { $0.contains(":") })
    }

    // MARK: - Interactive web auth

    public func interactiveLoginEvents() async -> AsyncThrowingStream<VaultTailnetAuthEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.runInteractiveLogin(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runInteractiveLogin(
        _ continuation: AsyncThrowingStream<VaultTailnetAuthEvent, Error>.Continuation) async {
        do {
            let node = try runningNode()
            if let summary = await statusSummary(), summary.backend == .running {
                continuation.yield(.running(summary))
                continuation.finish()
                return
            }
            let client = LocalAPIClient(localNode: node, logger: logger)
            let consumer = VaultTailnetLoginConsumer { [weak self] step in
                guard let self else { return }
                switch step {
                case .browse(let url):
                    continuation.yield(.browseToURL(url))
                case .finished:
                    continuation.yield(.loginFinished)
                    Task {
                        do {
                            let summary = try await self.bringUp()
                            continuation.yield(.running(summary))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                case .failed(let message):
                    continuation.finish(throwing: VaultTailnetError.unavailable(message))
                case .none:
                    break
                }
            }
            let processor = try await client.watchIPNBus(
                mask: [.initialState, .rateLimitNetmaps], consumer: consumer)
            continuation.onTermination = { _ in processor.cancel() }
            try await client.startLoginInteractive()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    // MARK: - Dialing

    /// Brings the node up when it already holds a login. Never triggers
    /// interactive auth: an unauthenticated node reports `.needsLogin` so
    /// callers surface an honest unavailable state.
    @discardableResult
    public func ensureRunningWithExistingLogin() async throws -> VaultTailnetStatusSummary {
        guard node != nil || hasPersistedState else { throw VaultTailnetError.needsLogin }
        let summary = await statusSummary()
        switch summary?.backend {
        case .running:
            return summary!
        case .needsLogin, .noState:
            throw VaultTailnetError.needsLogin
        default:
            return try await bringUp()
        }
    }

    func currentHandle() async throws -> TailscaleHandle? {
        try await runningNode().tailscale
    }

    public func dialTailnet(host: String, port: UInt16) async throws -> Int32 {
        try await ensureRunningWithExistingLogin()
        let node = try runningNode()
        let address = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        guard let handle = await node.tailscale else {
            throw VaultTailnetError.unavailable("no tailscale handle")
        }
        return try await runBlocking {
            try TailscaleSocket.dial(handle, address: address)
        }
    }

    /// `tailscale_up` blocks until the node is usable and does not observe
    /// task cancellation. The documented way to interrupt it is
    /// `tailscale_close`, so a timeout closes and discards the node; the next
    /// attempt recreates it from persisted state.
    @discardableResult
    private func bringUp() async throws -> VaultTailnetStatusSummary {
        let node = try runningNode()
        let outcome = VaultTailnetFirstOutcome()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached {
                do {
                    try await node.up()
                    if outcome.take() { continuation.resume() }
                } catch {
                    if outcome.take() { continuation.resume(throwing: error) }
                }
            }
            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.upTimeout * 1_000_000_000))
                guard outcome.take() else { return }
                continuation.resume(throwing: VaultTailnetError.timedOut)
                await self?.discardNode(node)
            }
        }
        guard let summary = await statusSummary(), summary.backend == .running else {
            throw VaultTailnetError.unavailable("node did not reach Running")
        }
        return summary
    }

    private func discardNode(_ staleNode: TailscaleNode) async {
        if node === staleNode { node = nil }
        try? await staleNode.close()
    }

    // MARK: - Logout

    public func logout() async throws {
        let node = try runningNode()
        let client = LocalAPIClient(localNode: node, logger: logger)
        try await client.logout()
    }

    private func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            blockingQueue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}

extension VaultTailnetNodeRunner: VaultTailnetControlling {}

/// Reduces IPN bus notifications to the auth-flow steps Vault reacts to.
/// Pure over primitives so tests can drive it without a live node.
public enum VaultTailnetLoginStep: Equatable, Sendable {
    case none
    case browse(URL)
    case finished
    case failed(String)

    public static func reduce(browseToURL: String?, loginFinished: Bool,
                              stateRaw: Int?, errMessage: String?) -> VaultTailnetLoginStep {
        if let errMessage, !errMessage.isEmpty { return .failed(errMessage) }
        if loginFinished || stateRaw == Ipn.State.Running.rawValue { return .finished }
        if let browseToURL, let url = URL(string: browseToURL),
           url.scheme == "https" || url.scheme == "http" {
            return .browse(url)
        }
        return .none
    }
}

private actor VaultTailnetLoginConsumer: MessageConsumer {
    private let handler: @Sendable (VaultTailnetLoginStep) -> Void
    private var loginObserved = false

    init(handler: @escaping @Sendable (VaultTailnetLoginStep) -> Void) {
        self.handler = handler
    }

    func notify(_ notify: Ipn.Notify) {
        let step = VaultTailnetLoginStep.reduce(browseToURL: notify.BrowseToURL,
                                                loginFinished: notify.LoginFinished != nil,
                                                stateRaw: notify.State?.rawValue,
                                                errMessage: notify.ErrMessage)
        // The bus repeats Running state updates; forward the terminal step once.
        if step == .finished {
            guard !loginObserved else { return }
            loginObserved = true
        }
        handler(step)
    }

    func error(_ error: Error) {
        handler(.failed(String(describing: error)))
    }
}

public struct VaultTailnetLogSink: LogSink {
    public var logFileHandle: Int32?
    private let logger = os.Logger(subsystem: "com.hsanabria.luna.vault", category: "tailnet")
    public init() {}
    public func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}

/// Hands the continuation to whichever side finishes first; the loser's
/// resume attempt is dropped.
private final class VaultTailnetFirstOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}
