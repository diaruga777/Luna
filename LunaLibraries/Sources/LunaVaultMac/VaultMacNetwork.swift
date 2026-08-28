import Foundation
import LunaVaultBackend

#if canImport(Network)
import Network

/// Length-prefixed transport for authenticated Vault frames. It is deliberately
/// agnostic to whether the endpoint is a Tailscale IP, MagicDNS name, or a LAN
/// Bonjour result. The application frame is authenticated before dispatch.
public final class VaultMacNWFrameChannel: VaultMacFrameChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.hsanabria.luna.vault.mac-transport")

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func start() {
        connection.start(queue: queue)
    }

    public func send(_ frame: Data) async throws {
        guard frame.count <= VaultMacProtocol.maximumFrameBytes else { throw VaultMacProtocolError.frameTooLarge }
        var length = UInt32(frame.count).bigEndian
        var data = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        data.append(frame)
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    public func receive() async throws -> Data {
        let header = try await receiveExactly(4)
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, length <= UInt32(VaultMacProtocol.maximumFrameBytes) else {
            throw VaultMacProtocolError.frameTooLarge
        }
        return try await receiveExactly(Int(length))
    }

    public func close() {
        connection.cancel()
    }

    private func receiveExactly(_ length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == length {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: VaultMacProtocolError.invalidFrame)
                } else {
                    continuation.resume(throwing: VaultMacProtocolError.invalidFrame)
                }
            }
        }
    }
}

/// Minimal companion listener. Pairing is intentionally completed before
/// constructing this listener: the caller supplies the paired secret and the
/// listener only accepts authenticated frames for that session. This prevents
/// a LAN/Tailscale peer from turning reachability into authorization.
public final class VaultMacTCPListener: @unchecked Sendable {
    public let port: UInt16
    private let listener: NWListener
    private let service: VaultMacCompanionService
    private let secret: VaultMacPairingSecret
    private let sessionID: UUID

    public init(port: UInt16 = 49_200, service: VaultMacCompanionService, secret: VaultMacPairingSecret, sessionID: UUID) throws {
        guard port != 0 else { throw VaultMacProtocolError.invalidRequest }
        self.port = port
        self.listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        self.service = service
        self.secret = secret
        self.sessionID = sessionID
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let channel = VaultMacNWFrameChannel(connection: connection)
            channel.start()
            Task { await self.serve(channel) }
        }
        listener.start(queue: DispatchQueue(label: "com.hsanabria.luna.vault.mac-listener"))
    }

    public func stop() {
        listener.cancel()
    }

    private func serve(_ channel: VaultMacNWFrameChannel) async {
        let replay = VaultMacReplayGuard(secret: secret, sessionID: sessionID)
        let sender = VaultMacSendSequence(secret: secret, sessionID: sessionID)
        defer { channel.close() }
        do {
            while true {
                let encoded = try await channel.receive()
                let frame = try JSONDecoder().decode(VaultMacAuthenticatedFrame.self, from: encoded)
                let body = try replay.open(frame)
                let request = try JSONDecoder().decode(VaultMacRequest.self, from: body)
                let response = await service.handle(request)
                let responseBody = try JSONEncoder().encode(response)
                let responseFrame = try sender.seal(responseBody)
                try await channel.send(JSONEncoder().encode(responseFrame))
            }
        } catch {
            // Disconnects and malformed/replayed frames are intentionally
            // terminal for this connection; no request is retried implicitly.
        }
    }
}
#endif
