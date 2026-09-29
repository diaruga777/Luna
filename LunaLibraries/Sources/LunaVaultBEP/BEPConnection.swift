import Foundation

/// What a connection owner handles. Requests run concurrently, one task each,
/// as Syncthing does; everything else arrives in wire order.
public protocol BEPConnectionDelegate: AnyObject, Sendable {
    func connection(_ connection: BEPConnection, didReceive clusterConfig: BEPClusterConfig) async
    func connection(_ connection: BEPConnection, didReceive index: BEPIndex) async
    func connection(_ connection: BEPConnection, didReceive downloadProgress: BEPDownloadProgress) async
    /// Returns the block bytes, or an error code the connection sends back.
    func connection(_ connection: BEPConnection, serve request: BEPRequest) async -> Result<Data, BEPErrorCode>
    func connection(_ connection: BEPConnection, didSend responseFor: BEPRequest, byteCount: Int) async
    func connection(_ connection: BEPConnection, didCloseWith error: Error?) async
}

public extension BEPConnectionDelegate {
    func connection(_ connection: BEPConnection, didReceive downloadProgress: BEPDownloadProgress) async {}
    func connection(_ connection: BEPConnection, didSend responseFor: BEPRequest, byteCount: Int) async {}
}

public struct BEPConnectionTiming: Sendable {
    public var pingInterval: TimeInterval = 45
    public var receiveTimeout: TimeInterval = 300
    public var requestTimeout: TimeInterval = 180
    public var helloTimeout: TimeInterval = 20
    public var timerTick: TimeInterval = 5
    public init() {}
}

/// One BEP session over an authenticated stream (`§A.4`).
///
/// Call `start()` to exchange Hellos, then `send(clusterConfig:)` before any
/// other message. The read loop enforces the same rule on the peer.
public actor BEPConnection {
    public let stream: any BEPByteStream
    public let localHello: BEPHello
    public let peerDevice: DeviceID
    public private(set) var peerHello: BEPHello?
    public private(set) var bytesSent: Int64 = 0
    public private(set) var bytesReceived: Int64 = 0

    private weak var delegate: (any BEPConnectionDelegate)?
    private let timing: BEPConnectionTiming
    private var clock: @Sendable () -> Date

    private var readTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var closed = false
    private var closeError: Error?
    private var sentClusterConfig = false
    private var receivedClusterConfig = false
    private var lastWrite: Date
    private var lastRead: Date
    private var nextRequestID: Int32 = 1
    private struct PendingRequest {
        let continuation: CheckedContinuation<BEPResponse, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int32: PendingRequest] = [:]

    public init(stream: any BEPByteStream, peerDevice: DeviceID, localHello: BEPHello,
                delegate: any BEPConnectionDelegate, timing: BEPConnectionTiming = BEPConnectionTiming(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.stream = stream
        self.peerDevice = peerDevice
        self.localHello = localHello
        self.delegate = delegate
        self.timing = timing
        self.clock = clock
        lastWrite = clock()
        lastRead = clock()
    }

    public var isClosed: Bool { closed }

    /// Exchanges Hellos and starts the read loop and timers.
    @discardableResult
    public func start() async throws -> BEPHello {
        let helloBytes = try BEPFraming.encodeHello(localHello)
        try await stream.write(helloBytes)
        bytesSent += Int64(helloBytes.count)
        let peer = try await withTimeout(timing.helloTimeout, onTimeout: { [stream] in stream.close() }) { [stream] in
            try await BEPFraming.readHello(from: stream)
        }
        peerHello = peer
        lastRead = clock()
        lastWrite = clock()
        readTask = Task { [weak self] in await self?.readLoop() }
        timerTask = Task { [weak self] in await self?.timerLoop() }
        return peer
    }

    // MARK: Sending

    public func send(clusterConfig: BEPClusterConfig) async throws {
        try await write(.clusterConfig(clusterConfig))
        sentClusterConfig = true
    }

    public func send(index: BEPIndex) async throws {
        for file in index.files { try file.validateForWire() }
        try await write(.index(index))
    }

    public func send(downloadProgress: BEPDownloadProgress) async throws {
        try await write(.downloadProgress(downloadProgress))
    }

    /// Requests one block and waits for the peer's answer.
    public func request(folder: String, name: String, block: BlockInfo, blockNo: Int32) async throws -> Data {
        let request = BEPRequest(id: allocateRequestID(), folder: folder, name: name, offset: block.offset,
                                 size: block.size, hash: block.hash, blockNo: blockNo)
        try request.validateForWire()
        let response = try await sendRequest(request)
        guard SHA256Digest.hash(response.data) == block.hash else { throw BEPRequestError.hashMismatch }
        return response.data
    }

    /// Browser replies have no pre-indexed hash: TLS authenticates these live
    /// responses. Normal sync block requests above always retain hash checking.
    public func browseMac(_ operation: VaultMacBrowseRequest) async throws -> VaultMacBrowseResponse {
        let request = BEPRequest(id: allocateRequestID(), folder: VaultMacBrowseProtocol.folder,
            name: try operation.encodedName(), offset: 0, size: 0, hash: Data())
        let response: BEPResponse
        do { response = try await sendRequest(request) }
        catch BEPRequestError.peerCode {
            throw VaultMacBrowseError("Mac browsing is unavailable. Update and reopen Luna Vault on your Mac, then reconnect.")
        }
        guard response.data.count <= VaultMacBrowseProtocol.maximumResponseSize else {
            throw VaultMacBrowseError("The Mac returned too much browser data.")
        }
        let value = try JSONDecoder().decode(VaultMacBrowseResponse.self, from: response.data)
        if let error = value.error { throw VaultMacBrowseError(error) }
        return value
    }

    private func sendRequest(_ request: BEPRequest) async throws -> BEPResponse {
        let response: BEPResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let deadline = Task { [weak self, timeout = timing.requestTimeout] in
                    do { try await Task.sleep(for: .seconds(timeout)) }
                    catch { return }
                    await self?.timeoutRequest(id: request.id)
                }
                pending[request.id] = PendingRequest(continuation: continuation, timeout: deadline)
                Task { [weak self] in
                    do { try await self?.write(.request(request)) }
                    catch { await self?.failPending(id: request.id, error: error) }
                }
            }
        } onCancel: {
            Task { await self.failPending(id: request.id, error: CancellationError()) }
        }
        guard response.code == .noError else { throw BEPRequestError.peerCode(response.code) }
        return response
    }

    public func sendPing() async throws {
        try await write(.ping)
    }

    /// Sends Close and tears the connection down.
    public func close(reason: String) async {
        guard !closed else { return }
        // A stalled socket may never finish a write. Bound the courtesy
        // Close frame so reconnect can always tear down the old stream.
        let deadline = Task { [stream] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            stream.close()
        }
        defer { deadline.cancel() }
        try? await write(.close(BEPClose(reason: reason)))
        await tearDown(error: nil)
    }

    private func allocateRequestID() -> Int32 {
        defer { nextRequestID = nextRequestID == Int32.max ? 1 : nextRequestID + 1 }
        return nextRequestID
    }

    private func write(_ message: BEPMessage) async throws {
        guard !closed else { throw BEPStreamError.closed }
        if case .clusterConfig = message {} else if !sentClusterConfig, message.type != .close {
            throw BEPProtocolError.clusterConfigExpected
        }
        let frame = BEPFraming.encodeMessage(message)
        do { try await stream.write(frame) }
        catch {
            await tearDown(error: error)
            throw error
        }
        bytesSent += Int64(frame.count)
        lastWrite = clock()
    }

    private func failPending(id: Int32, error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: error)
    }

    private func timeoutRequest(id: Int32) async {
        guard pending[id] != nil else { return }
        failPending(id: id, error: BEPStreamError.timedOut)
        await tearDown(error: BEPStreamError.timedOut)
    }

    // MARK: Receiving

    private func readLoop() async {
        while !closed {
            do {
                let message = try await BEPFraming.readMessage(from: stream)
                lastRead = clock()
                try await dispatch(message)
            } catch {
                await tearDown(error: closed ? nil : error)
                return
            }
        }
    }

    private func dispatch(_ message: BEPMessage) async throws {
        if !receivedClusterConfig {
            switch message {
            case .clusterConfig: receivedClusterConfig = true
            case .close(let close): throw BEPProtocolError.closedByPeer(close.reason)
            case .unknown: return
            default: throw BEPProtocolError.clusterConfigExpected
            }
        }
        switch message {
        case .clusterConfig(let config):
            await delegate?.connection(self, didReceive: config)
        case .index(let index):
            await delegate?.connection(self, didReceive: index)
        case .request(let request):
            Task { [weak self] in
                guard let self else { return }
                let result = await self.serve(request)
                let response: BEPResponse
                switch result {
                case .success(let data): response = BEPResponse(id: request.id, data: data)
                case .failure(let code): response = BEPResponse(id: request.id, data: Data(), code: code)
                }
                do {
                    try await self.write(.response(response))
                    if case .success(let data) = result {
                        await self.delegate?.connection(self, didSend: request, byteCount: data.count)
                    }
                } catch { /* Connection teardown retries the pending file. */ }
            }
        case .response(let response):
            if let request = pending.removeValue(forKey: response.id) {
                request.timeout.cancel()
                request.continuation.resume(returning: response)
            }
        case .downloadProgress(let progress):
            await delegate?.connection(self, didReceive: progress)
        case .ping, .unknown:
            break
        case .close(let close):
            throw BEPProtocolError.closedByPeer(close.reason)
        }
    }

    private func serve(_ request: BEPRequest) async -> Result<Data, BEPErrorCode> {
        guard let delegate else { return .failure(.generic) }
        return await delegate.connection(self, serve: request)
    }

    // MARK: Timers

    private func timerLoop() async {
        while !closed {
            try? await Task.sleep(nanoseconds: UInt64(timing.timerTick * 1_000_000_000))
            if closed { return }
            let now = clock()
            if now.timeIntervalSince(lastRead) > timing.receiveTimeout {
                await tearDown(error: BEPProtocolError.receiveTimeout)
                return
            }
            if sentClusterConfig, now.timeIntervalSince(lastWrite) >= timing.pingInterval {
                try? await write(.ping)
            }
        }
    }

    /// Runs one timer pass now. Tests drive time through this.
    public func tickForTesting() async {
        let now = clock()
        if now.timeIntervalSince(lastRead) > timing.receiveTimeout {
            await tearDown(error: BEPProtocolError.receiveTimeout)
            return
        }
        if sentClusterConfig, now.timeIntervalSince(lastWrite) >= timing.pingInterval {
            try? await write(.ping)
        }
    }

    private func tearDown(error: Error?) async {
        guard !closed else { return }
        closed = true
        closeError = error
        stream.close()
        timerTask?.cancel()
        for (_, request) in pending {
            request.timeout.cancel()
            request.continuation.resume(throwing: error ?? BEPStreamError.closed)
        }
        pending.removeAll()
        await delegate?.connection(self, didCloseWith: error)
    }
}

public enum BEPRequestError: Error, Equatable, LocalizedError {
    case peerCode(BEPErrorCode)
    case hashMismatch

    public var errorDescription: String? {
        switch self {
        case .peerCode(.noSuchFile): return "The Mac no longer has this version of the file. Refresh Vault and try again."
        case .peerCode: return "The Mac couldn’t send this file. Keep Luna Vault open on the Mac and try again."
        case .hashMismatch: return "The file changed while downloading. Refresh Vault and try again."
        }
    }
}

/// Fails after `seconds` with `BEPStreamError.timedOut`.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void = {}, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            onTimeout()
            throw BEPStreamError.timedOut
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
