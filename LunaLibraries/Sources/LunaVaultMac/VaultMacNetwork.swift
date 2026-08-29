import Foundation
import LunaVaultBackend

#if canImport(Network)
import Network

public protocol VaultMacBonjourPublishing: Sendable {
    func start()
    func stop()
}

public struct VaultMacListenerLimits: Equatable, Sendable {
    public let maximumConnections: Int
    public let authenticationTimeout: TimeInterval
    public let idleTimeout: TimeInterval
    public let maximumAuthenticationFailuresPerMinute: Int
    public init(maximumConnections: Int = 8, authenticationTimeout: TimeInterval = 10,
                idleTimeout: TimeInterval = 60,
                maximumAuthenticationFailuresPerMinute: Int = 5) {
        self.maximumConnections = max(1, min(maximumConnections, 32))
        self.authenticationTimeout = max(1, min(authenticationTimeout, 30))
        self.idleTimeout = max(5, min(idleTimeout, 300))
        self.maximumAuthenticationFailuresPerMinute = max(1, maximumAuthenticationFailuresPerMinute)
    }
}

private final class VaultMacConnectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: VaultMacListenerLimits
    private var active = 0
    private var failures: [String: [Date]] = [:]
    init(limits: VaultMacListenerLimits) { self.limits = limits }
    func begin(peer: String, now: Date) -> Bool {
        lock.withLock {
            let recent = failures[peer, default: []].filter { now.timeIntervalSince($0) < 60 }
            let global = failures["*", default: []].filter { now.timeIntervalSince($0) < 60 }
            failures[peer] = recent
            failures["*"] = global
            guard active < limits.maximumConnections,
                  recent.count < limits.maximumAuthenticationFailuresPerMinute,
                  global.count < limits.maximumAuthenticationFailuresPerMinute * limits.maximumConnections else {
                return false
            }
            active += 1; return true
        }
    }
    func end() { lock.withLock { active = max(0, active - 1) } }
    func failed(peer: String, now: Date) {
        lock.withLock {
            failures[peer, default: []].append(now)
            failures["*", default: []].append(now)
        }
    }
}

/// The listener cannot be constructed without an already-paired authority and
/// a concrete non-wildcard bind host. It authenticates a fresh challenge before
/// accepting encrypted application frames.
public final class VaultMacTCPListener: VaultMacBonjourPublishing, @unchecked Sendable {
    public let port: UInt16
    private let listener: NWListener
    private let service: VaultMacCompanionService
    private let authority: VaultMacSessionAuthority
    private let limits: VaultMacListenerLimits
    private let gate: VaultMacConnectionGate

    public init(bindHost: String, port: UInt16 = 49_200, advertiseName: String? = nil,
                service: VaultMacCompanionService, authority: VaultMacSessionAuthority,
                limits: VaultMacListenerLimits = VaultMacListenerLimits()) throws {
        guard port > 0, !bindHost.isEmpty, bindHost != "0.0.0.0", bindHost != "::" else {
            throw VaultMacProtocolError.invalidEndpoint
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost),
                                                      port: NWEndpoint.Port(rawValue: port)!)
        self.port = port; self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        if let advertiseName, !advertiseName.isEmpty {
            listener.service = NWListener.Service(name: advertiseName,
                type: VaultMacProtocol.serviceType, domain: "local", txtRecord: nil)
        }
        self.service = service; self.authority = authority; self.limits = limits
        self.gate = VaultMacConnectionGate(limits: limits)
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: DispatchQueue(label: "com.hsanabria.luna.vault.mac-listener"))
    }
    public func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        let peer = String(describing: connection.endpoint), now = Date()
        guard gate.begin(peer: peer, now: now) else { connection.cancel(); return }
        let channel = VaultMacNWFrameChannel(connection: connection); channel.start()
        Task { [weak self] in
            defer { channel.close(); self?.gate.end() }
            do { try await self?.serve(channel) }
            catch { self?.gate.failed(peer: peer, now: Date()) }
        }
    }

    private func serve(_ channel: VaultMacNWFrameChannel) async throws {
        let challenge = try authority.issue(lifetime: limits.authenticationTimeout)
        try await channel.send(JSONEncoder().encode(VaultMacHandshakeMessage(kind: .challenge, challenge: challenge)))
        let responseData = try await withTimeout(seconds: limits.authenticationTimeout) { try await channel.receive() }
        let message = try JSONDecoder().decode(VaultMacHandshakeMessage.self, from: responseData)
        guard message.kind == .response, let response = message.response else { throw VaultMacProtocolError.authenticationFailed }
        let (_, keys) = try authority.accept(response)
        try await channel.send(JSONEncoder().encode(VaultMacHandshakeMessage(kind: .accepted)))
        let receiver = VaultMacReplayGuard(key: keys.requestKey, sessionID: challenge.sessionID, direction: .request)
        let sender = VaultMacSendSequence(key: keys.responseKey, sessionID: challenge.sessionID, direction: .response)
        while true {
            let encoded = try await withTimeout(seconds: limits.idleTimeout) { try await channel.receive() }
            let frame = try JSONDecoder().decode(VaultMacAuthenticatedFrame.self, from: encoded)
            let request = try JSONDecoder().decode(VaultMacRequest.self, from: receiver.open(frame))
            let response = await service.handle(request)
            try await channel.send(JSONEncoder().encode(try sender.seal(JSONEncoder().encode(response))))
        }
    }
}

private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                      operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw VaultMacProtocolError.expired
        }
        guard let result = try await group.next() else { throw VaultMacProtocolError.unavailable }
        group.cancelAll(); return result
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
#endif
