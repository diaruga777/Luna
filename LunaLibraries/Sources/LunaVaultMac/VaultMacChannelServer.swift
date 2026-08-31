import Foundation
import LunaVaultBackend

public struct VaultMacListenerLimits: Equatable, Sendable {
    public let maximumConnections: Int
    public let authenticationTimeout: TimeInterval
    public let idleTimeout: TimeInterval
    public let maximumAuthenticationFailuresPerMinute: Int
    public init(maximumConnections: Int = 8, authenticationTimeout: TimeInterval = 10,
                idleTimeout: TimeInterval = 60,
                maximumAuthenticationFailuresPerMinute: Int = 5) {
        self.maximumConnections = max(1, min(maximumConnections, 32))
        self.authenticationTimeout = Self.clamp(authenticationTimeout, lower: 1, upper: 30,
                                               fallback: 10)
        self.idleTimeout = Self.clamp(idleTimeout, lower: 5, upper: 300, fallback: 60)
        self.maximumAuthenticationFailuresPerMinute = max(1,
            min(maximumAuthenticationFailuresPerMinute, 1_000))
    }
    private static func clamp(_ value: TimeInterval, lower: TimeInterval,
                              upper: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        value.isFinite ? min(max(value, lower), upper) : fallback
    }
}

/// Bounds concurrent sessions and authentication failures across every
/// transport that feeds the companion, so a Tailscale listener and a LAN
/// listener draw from one shared budget.
public final class VaultMacConnectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: VaultMacListenerLimits
    private var active = 0
    private var failures: [String: [Date]] = [:]
    public init(limits: VaultMacListenerLimits) { self.limits = limits }
    public func begin(peer: String, now: Date) -> Bool {
        lock.withLock {
            let recent = failures[peer, default: []].filter { now.timeIntervalSince($0) < 60 }
            let global = failures["*", default: []].filter { now.timeIntervalSince($0) < 60 }
            failures[peer] = recent
            failures["*"] = global
            let (globalLimit, overflow) = limits.maximumAuthenticationFailuresPerMinute
                .multipliedReportingOverflow(by: limits.maximumConnections)
            guard !overflow, active < limits.maximumConnections,
                  recent.count < limits.maximumAuthenticationFailuresPerMinute,
                  global.count < globalLimit else {
                return false
            }
            active += 1; return true
        }
    }
    public func end() { lock.withLock { active = max(0, active - 1) } }
    public func failed(peer: String, now: Date) {
        lock.withLock {
            failures[peer, default: []].append(now)
            failures["*", default: []].append(now)
        }
    }
}

/// Runs the companion's authenticated session protocol over any
/// `VaultMacFrameChannel`. Listeners own accept and transport; this owns the
/// challenge handshake, replay guards, and the request/response loop.
public final class VaultMacChannelServer: Sendable {
    private let service: VaultMacCompanionService
    private let authority: VaultMacSessionAuthority
    private let limits: VaultMacListenerLimits
    private let gate: VaultMacConnectionGate

    public init(service: VaultMacCompanionService, authority: VaultMacSessionAuthority,
                limits: VaultMacListenerLimits = VaultMacListenerLimits(),
                gate: VaultMacConnectionGate? = nil) {
        self.service = service; self.authority = authority; self.limits = limits
        self.gate = gate ?? VaultMacConnectionGate(limits: limits)
    }

    /// Admits the peer through the shared gate, serves the channel until it
    /// fails or idles out, and records an authentication failure against the
    /// peer on error. Closes the channel before returning.
    public func run(_ channel: any VaultMacFrameChannel, peer: String) async {
        guard gate.begin(peer: peer, now: Date()) else { channel.close(); return }
        defer { channel.close(); gate.end() }
        do { try await serve(channel) }
        catch { gate.failed(peer: peer, now: Date()) }
    }

    private func serve(_ channel: any VaultMacFrameChannel) async throws {
        let challenge = try authority.issue(lifetime: limits.authenticationTimeout)
        try await channel.send(JSONEncoder().encode(VaultMacHandshakeMessage(kind: .challenge, challenge: challenge)))
        let responseData = try await withTimeout(seconds: limits.authenticationTimeout) { try await channel.receive() }
        let message = try JSONDecoder().decode(VaultMacHandshakeMessage.self, from: responseData)
        guard message.kind == .response, let response = message.response else { throw VaultMacProtocolError.authenticationFailed }
        let (_, keys, acceptance) = try authority.accept(response)
        try await channel.send(JSONEncoder().encode(VaultMacHandshakeMessage(
            kind: .accepted, acceptance: acceptance)))
        let receiver = VaultMacReplayGuard(key: keys.requestKey, sessionID: challenge.sessionID, direction: .request)
        let sender = VaultMacSendSequence(key: keys.responseKey, sessionID: challenge.sessionID, direction: .response)
        while true {
            guard authority.isCredentialUsable(epoch: challenge.credentialEpoch) else {
                throw VaultMacProtocolError.revoked
            }
            let encoded = try await withTimeout(seconds: limits.idleTimeout) { try await channel.receive() }
            let frame = try JSONDecoder().decode(VaultMacAuthenticatedFrame.self, from: encoded)
            let request = try JSONDecoder().decode(VaultMacRequest.self, from: receiver.open(frame))
            guard authority.isCredentialUsable(epoch: challenge.credentialEpoch) else {
                throw VaultMacProtocolError.revoked
            }
            let response = await service.handle(request)
            try await channel.send(JSONEncoder().encode(try sender.seal(JSONEncoder().encode(response))))
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
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
