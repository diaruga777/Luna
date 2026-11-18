import Foundation
import IrohLib
import LunaVaultBEP
import Network

/// Iroh connects the two sockets. The BEP listener still authenticates the
/// phone’s certificate and the BEP client still pins the Mac’s certificate.
public actor VaultIrohTransport {
    private static let alpn = Data("luna-vault/direct/1".utf8)
    private let directory: URL
    private let preset: @Sendable () -> any Preset
    private var server: Endpoint?
    private var acceptTask: Task<Void, Never>?

    public func waitForListenerToClose() async { await acceptTask?.value }
    private var binding: Task<Endpoint, Error>?
    private var directAddresses: [String: String] = [:]

    public init(directory: URL) {
        self.directory = directory
        preset = { presetN0() }
    }

    init(directory: URL, preset: @escaping @Sendable () -> any Preset) {
        self.directory = directory
        self.preset = preset
    }

    func listeningAddresses() -> [String] { server?.addr().directAddresses() ?? [] }

    public func stop() async throws {
        let listening = server
        let dialing = binding
        server = nil
        binding = nil
        try await listening?.close()
        if let endpoint = try await dialing?.value { try await endpoint.close() }
    }

    private func endpoint() async throws -> Endpoint {
        if let binding { return try await binding.value }
        // The client endpoint is ephemeral. Its BEP certificate is shared by
        // the Luna apps, so they can connect concurrently under the same account.
        let task = Task {
            try await Endpoint.bind(options: EndpointOptions(preset: preset()))
        }
        binding = task
        do { return try await task.value }
        catch { binding = nil; throw error }
    }

    public func listen(port: UInt16) async throws -> VaultPeerAddress {
        let key = try Self.loadServerKey(directory: directory)
        let endpoint = try await Endpoint.bind(options: .init(preset: preset(), secretKey: key, alpns: [Self.alpn]))
        server = endpoint
        acceptTask = Task {
            while let incoming = await endpoint.acceptNext() {
                Task {
                    let connection: Connection
                    do { connection = try await incoming.accept().connect() }
                    catch { return }
                    defer { try? connection.close(errorCode: 0, reason: Data()) }
                    do {
                        try await IrohDirectConnection.awaitDirect(connection)
                        let watch = IrohDirectConnection.stopOnPathLoss(connection)
                        defer { watch.cancel() }
                        let stream = try await IrohDirectConnection.within(.seconds(10)) { try await connection.acceptBi() }
                        guard let port = NWEndpoint.Port(rawValue: port) else { return }
                        await Self.forward(stream, connection: connection,
                            local: NWConnection(host: "127.0.0.1", port: port, using: .tcp))
                    } catch { }
                }
            }
        }
        return .iroh(endpoint: endpoint.id().toBytes().map { String(format: "%02x", $0) }.joined())
    }

    func dial(_ id: String, tls: LunaVaultGoTransport, expecting device: DeviceID, direct: [String] = []) async throws -> any BEPByteStream {
        let endpoint = try await endpoint()
        let remote = try EndpointId.fromString(s: id)
        var connection: Connection?
        if let address = directAddresses[id] {
            connection = try? await IrohDirectConnection.connect(from: endpoint,
                to: EndpointAddr(id: remote, relayUrl: nil, addresses: [address]), alpn: Self.alpn, timeout: .milliseconds(700))
        }
        if connection == nil {
            try Task.checkCancellation()
            connection = try await IrohDirectConnection.connect(from: endpoint,
                to: EndpointAddr(id: remote, relayUrl: nil, addresses: direct), alpn: Self.alpn)
        }
        guard let connection else { throw IrohDirectConnection.Unavailable() }
        directAddresses[id] = connection.paths().first { $0.isSelected && $0.isIp }?.remoteAddr
        var loopback: NWListener?
        do {
            let stream = try await connection.openBi()
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: params)
            loopback = listener
            let port = try await IrohDirectConnection.within(.seconds(2)) {
                try await Self.start(listener, stream: stream, connection: connection)
            }
            let result = try await tls.dialTCP(.tcp(host: "127.0.0.1", port: port), expecting: device, localProbe: false)
            try Task.checkCancellation()
            return result
        } catch {
            loopback?.cancel()
            try? connection.close(errorCode: 0, reason: Data())
            throw error
        }
    }

    private static let queue = DispatchQueue(label: "luna.vault.iroh-loopback")

    // These values are only read or changed on `queue` by NWListener callbacks.
    private final class ListenerState: @unchecked Sendable {
        var pending: CheckedContinuation<UInt16, Error>?
        var accepted = false
        init(_ pending: CheckedContinuation<UInt16, Error>) { self.pending = pending }
        func finish(_ result: Result<UInt16, Error>) {
            let continuation = pending
            pending = nil
            continuation?.resume(with: result)
        }
    }

    private static func start(_ listener: NWListener, stream: BiStream, connection: Connection) async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = ListenerState(continuation)
                listener.stateUpdateHandler = { [weak listener] status in
                    switch status {
                    case .ready:
                        if let port = listener?.port { state.finish(.success(port.rawValue)) }
                        else { state.finish(.failure(VaultTransportError.notSupported)) }
                    case .failed(let error): state.finish(.failure(error))
                    case .cancelled: state.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak listener] local in
                    guard !state.accepted else { local.cancel(); return }
                    state.accepted = true
                    listener?.cancel()
                    Task {
                        let watch = IrohDirectConnection.stopOnPathLoss(connection)
                        defer { watch.cancel() }
                        await forward(stream, connection: connection, local: local)
                    }
                }
                listener.start(queue: queue)
            }
        } onCancel: { listener.cancel() }
    }

    private static func forward(_ stream: BiStream, connection: Connection, local: NWConnection) async {
        local.start(queue: queue)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let sender = stream.send()
                while let bytes = try? await receive(from: local), !bytes.isEmpty {
                    do { try await sender.writeAll(buf: bytes) }
                    catch { break }
                }
            }
            group.addTask {
                let receiver = stream.recv()
                while let bytes = try? await receiver.read(sizeLimit: 65_536), !bytes.isEmpty {
                    do { try await send(bytes, to: local) }
                    catch { break }
                }
            }
            _ = await group.next()
            local.cancel()
            try? connection.close(errorCode: 0, reason: Data())
            group.cancelAll()
        }
    }

    private static func receive(from local: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            local.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { bytes, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: bytes ?? Data()) }
            }
        }
    }

    private static func send(_ bytes: Data, to local: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            local.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private static func loadServerKey(directory: URL) throws -> Data {
        let path = directory.appendingPathComponent("vault-iroh.key")
        if FileManager.default.fileExists(atPath: path.path) { return try Data(contentsOf: path) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = SecretKey.generate().toBytes()
        try key.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return key
    }
}
