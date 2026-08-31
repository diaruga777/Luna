import Foundation
import LunaVaultBackend
#if canImport(Darwin)
import Darwin
#endif

#if canImport(Network)
import Network

public protocol VaultMacBonjourPublishing: Sendable {
    func start()
    func stop()
}

/// The listener cannot be constructed without an already-paired authority and
/// a concrete non-wildcard bind host. It authenticates a fresh challenge before
/// accepting encrypted application frames.
public final class VaultMacTCPListener: VaultMacBonjourPublishing, @unchecked Sendable {
    public let port: UInt16
    private let listener: NWListener
    private let server: VaultMacChannelServer

    public init(bindHost: String, port: UInt16 = 49_200, advertiseName: String? = nil,
                service: VaultMacCompanionService, authority: VaultMacSessionAuthority,
                limits: VaultMacListenerLimits = VaultMacListenerLimits(),
                gate: VaultMacConnectionGate? = nil) throws {
        guard port > 0, Self.isConcreteBindHost(bindHost) else {
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
        self.server = VaultMacChannelServer(service: service, authority: authority,
                                            limits: limits, gate: gate)
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: DispatchQueue(label: "com.hsanabria.luna.vault.mac-listener"))
    }
    public func stop() { listener.cancel() }

    private static func isConcreteBindHost(_ rawValue: String) -> Bool {
        let rawHost = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Accept the bracket spelling commonly used for IPv6 literals only as
        // presentation syntax. Canonicalize before checking wildcard forms so
        // `[*]`, `[::]`, and `[0.0.0.0]` cannot evade the bind guard.
        let host: String
        if rawHost.hasPrefix("[") || rawHost.hasSuffix("]") {
            guard rawHost.count >= 2, rawHost.first == "[", rawHost.last == "]" else { return false }
            host = String(rawHost.dropFirst().dropLast())
        } else {
            host = rawHost
        }
        guard !host.isEmpty, host != "*", host != "0" else { return false }
        if let bytes = ipv4Bytes(host), bytes.allSatisfy({ $0 == 0 }) { return false }
#if canImport(Darwin)
        var address = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 {
            return !withUnsafeBytes(of: &address) { $0.allSatisfy { $0 == 0 } }
        }
        #endif
        return true
    }

    private static func ipv4Bytes(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    private func accept(_ connection: NWConnection) {
        let peer = String(describing: connection.endpoint)
        let channel = VaultMacNWFrameChannel(connection: connection); channel.start()
        Task { [server] in await server.run(channel, peer: peer) }
    }
}
#endif
