import Foundation
import LunaVaultBackend
import os

private let serverLog = os.Logger(subsystem: "com.hsanabria.luna.vault", category: "mac-server")

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
            sweepStaleBucketsLocked(now: now)
            let recent = failures[peer, default: []].filter { now.timeIntervalSince($0) < 60 }
            let global = failures["*", default: []].filter { now.timeIntervalSince($0) < 60 }
            if recent.isEmpty { failures.removeValue(forKey: peer) } else { failures[peer] = recent }
            if global.isEmpty { failures.removeValue(forKey: "*") } else { failures["*"] = global }
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
    /// Every distinct peer string seen (one per connection, once the gate key
    /// is host-only rather than host:port) leaves a bucket behind even after
    /// its failures age out. Drop any bucket whose newest entry is already
    /// stale so a peer that only ever connects once does not linger forever.
    private func sweepStaleBucketsLocked(now: Date) {
        // Collect first: removing a key from `failures` while iterating it
        // directly is not safe.
        let stale = failures.compactMap { key, dates -> String? in
            guard key != "*", let newest = dates.max(), now.timeIntervalSince(newest) >= 60 else { return nil }
            return key
        }
        for key in stale { failures.removeValue(forKey: key) }
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

    /// The issued challenge's own validity window, kept independent of
    /// `authenticationTimeout` (the server's socket wait for the client's
    /// proof). Binding the two together made ordinary wire latency compete
    /// with cross-device clock skew: a phone whose clock ran ahead of the
    /// Mac's by more than `authenticationTimeout` failed every handshake with
    /// `expired`, even though session IDs are already single-use and do not
    /// depend on this window for replay safety.
    private static let challengeLifetime: TimeInterval = 90

    public init(service: VaultMacCompanionService, authority: VaultMacSessionAuthority,
                limits: VaultMacListenerLimits = VaultMacListenerLimits(),
                gate: VaultMacConnectionGate? = nil) {
        self.service = service; self.authority = authority; self.limits = limits
        self.gate = gate ?? VaultMacConnectionGate(limits: limits)
    }

    /// Admits the peer through the shared gate, serves the channel until it
    /// fails or idles out, and closes the channel before returning. Only a
    /// failure during the handshake — before a session is established — is
    /// charged against the peer's authentication-failure budget. A client
    /// that opens a fresh session per operation and closes cleanly when done,
    /// an idle timeout, and a mid-session revoke are all normal teardown of
    /// an already-authenticated session, not an attack signal.
    public func run(_ channel: any VaultMacFrameChannel, peer: String) async {
        let peerKey = Self.gateKey(for: peer)
        guard gate.begin(peer: peerKey, now: Date()) else {
            serverLog.error("Rejected \(peer, privacy: .public): connection or failure budget exhausted.")
            channel.close(); return
        }
        serverLog.info("Session opened for \(peer, privacy: .public).")
        defer { channel.close(); gate.end() }
        let session: VaultMacServerSession
        do {
            session = try await handshake(channel)
        } catch {
            serverLog.error("Handshake with \(peer, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            gate.failed(peer: peerKey, now: Date())
            return
        }
        do {
            try await sessionLoop(channel, session: session)
        } catch {
            serverLog.info("Session for \(peer, privacy: .public) ended: \(String(describing: error), privacy: .public)")
        }
    }

    /// Reduces a transport-supplied peer string to a host-only gate key.
    /// `String(describing: connection.endpoint)` (NW) and Go's
    /// `net.JoinHostPort` (tsnet, via `tailscale_getremoteaddr`) both render
    /// "host:port" — bracketed for an IPv6 literal — so every connection from
    /// the same host previously landed in its own single-use bucket and the
    /// per-peer half of the failure budget never accumulated.
    static func gateKey(for peer: String) -> String {
        if peer.hasPrefix("["), let closeBracket = peer.firstIndex(of: "]") {
            return String(peer[...closeBracket])
        }
        guard let lastColon = peer.lastIndex(of: ":") else { return peer }
        return String(peer[..<lastColon])
    }

    private struct VaultMacServerSession {
        let challenge: VaultMacSessionChallenge
        let receiver: VaultMacReplayGuard
        let sender: VaultMacSendSequence
    }

    /// Everything before a session is established: issuing the challenge,
    /// waiting for the client's proof, and accepting or rejecting it. Any
    /// error thrown here — a bad handshake frame, a failed proof, a replayed
    /// session ID, or a timeout before acceptance — is a pre-session failure.
    private func handshake(_ channel: any VaultMacFrameChannel) async throws -> VaultMacServerSession {
        let challenge = try authority.issue(lifetime: Self.challengeLifetime)
        try await send(VaultMacHandshakeMessage(kind: .challenge, challenge: challenge), over: channel)
        let responseData = try await withTimeout(seconds: limits.authenticationTimeout) { try await channel.receive() }
        let message = try JSONDecoder().decode(VaultMacHandshakeMessage.self, from: responseData)
        guard message.kind == .response, let response = message.response else {
            try? await send(VaultMacHandshakeMessage(kind: .rejected), over: channel)
            throw VaultMacProtocolError.authenticationFailed
        }
        do {
            let (acceptedChallenge, keys, acceptance) = try authority.accept(response)
            try await send(VaultMacHandshakeMessage(kind: .accepted, acceptance: acceptance), over: channel)
            let receiver = VaultMacReplayGuard(key: keys.requestKey, sessionID: acceptedChallenge.sessionID, direction: .request)
            let sender = VaultMacSendSequence(key: keys.responseKey, sessionID: acceptedChallenge.sessionID, direction: .response)
            return VaultMacServerSession(challenge: acceptedChallenge, receiver: receiver, sender: sender)
        } catch {
            // Tell a peer that failed the proof why, best-effort. A transport
            // error sending this notice must not mask the real failure below.
            try? await send(VaultMacHandshakeMessage(kind: .rejected), over: channel)
            throw error
        }
    }

    /// The authenticated request/response loop. Every error here — an idle
    /// timeout, a client that closes without a goodbye frame, a mid-session
    /// revoke — ends the loop but is normal teardown of an already-trusted
    /// session, not counted against the peer's failure budget.
    private func sessionLoop(_ channel: any VaultMacFrameChannel, session: VaultMacServerSession) async throws {
        while true {
            guard authority.isCredentialUsable(epoch: session.challenge.credentialEpoch) else {
                throw VaultMacProtocolError.revoked
            }
            let encoded = try await withTimeout(seconds: limits.idleTimeout) { try await channel.receive() }
            let frame = try JSONDecoder().decode(VaultMacAuthenticatedFrame.self, from: encoded)
            let request = try JSONDecoder().decode(VaultMacRequest.self, from: session.receiver.open(frame))
            guard authority.isCredentialUsable(epoch: session.challenge.credentialEpoch) else {
                throw VaultMacProtocolError.revoked
            }
            let response = await service.handle(request)
            serverLog.debug("Handled \(request.operation.rawValue, privacy: .public) object=\(request.objectID.rawValue.uuidString, privacy: .public) status=\(String(describing: response.status), privacy: .public)")
            let sealed = try JSONEncoder().encode(try session.sender.seal(JSONEncoder().encode(response)))
            try await withTimeout(seconds: limits.idleTimeout) { try await channel.send(sealed) }
        }
    }

    /// A stalled peer that stops reading must not hold this channel's slot
    /// forever: every send, handshake or in-session, is bounded the same way
    /// receives already were.
    private func send(_ message: VaultMacHandshakeMessage, over channel: any VaultMacFrameChannel) async throws {
        let encoded = try JSONEncoder().encode(message)
        try await withTimeout(seconds: limits.idleTimeout) { try await channel.send(encoded) }
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
