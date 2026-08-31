import Darwin
import Foundation
import LunaVaultBackend
import TailscaleKit

public struct VaultTailnetAcceptedConnection: Sendable {
    public let channel: VaultTailscaleFrameChannel
    public let peer: String
    public init(channel: VaultTailscaleFrameChannel, peer: String) {
        self.channel = channel
        self.peer = peer
    }
}

/// Accepts inbound tailnet connections for the Mac companion and wraps each
/// in a frame channel. Accept runs on its own queue in poll ticks so
/// `close()` from any thread stops the loop within one tick.
public final class VaultTailnetListener: @unchecked Sendable {
    private let handle: TailscaleHandle
    private let listener: TailscaleListener
    private let lock = NSLock()
    private var isClosed = false
    private let queue = DispatchQueue(label: "com.hsanabria.luna.vault.tailnet-listener")
    private static let pollTickMilliseconds: Int32 = 500

    init(handle: TailscaleHandle, listener: TailscaleListener) {
        self.handle = handle
        self.listener = listener
    }

    deinit {
        Darwin.close(listener)
    }

    public func close() {
        lock.lock()
        isClosed = true
        lock.unlock()
    }

    private var closed: Bool {
        lock.lock(); defer { lock.unlock() }
        return isClosed
    }

    public func connections() -> AsyncThrowingStream<VaultTailnetAcceptedConnection, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in self?.close() }
            queue.async { [self] in
                while !closed {
                    var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&descriptor, 1, Self.pollTickMilliseconds)
                    if closed { break }
                    if ready < 0, errno != EINTR {
                        continuation.finish(throwing: VaultTailnetError.unavailable("listener poll failed"))
                        return
                    }
                    guard ready > 0 else { continue }
                    do {
                        let (fd, remote) = try TailscaleSocket.accept(handle, listener: listener)
                        VaultTailnetLog.listener.info("Accepted tailnet connection from \(remote ?? "unknown", privacy: .public) fd=\(fd, privacy: .public)")
                        continuation.yield(VaultTailnetAcceptedConnection(
                            channel: VaultTailscaleFrameChannel(fileDescriptor: fd),
                            peer: remote ?? "unknown"))
                    } catch {
                        VaultTailnetLog.listener.error("Accept failed: \(String(describing: error), privacy: .public)")
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
        }
    }
}

extension VaultTailnetNodeRunner {
    /// Brings the node up and listens on the tailnet. `port` binds ":port"
    /// on the node's tailnet addresses only; nothing is exposed off-tailnet.
    public func tailnetListener(port: UInt16) async throws -> VaultTailnetListener {
        guard port > 0 else { throw VaultTailnetError.unavailable("invalid port") }
        try await ensureRunningWithExistingLogin()
        guard let handle = try await currentHandle() else {
            throw VaultTailnetError.unavailable("no tailscale handle")
        }
        let listener = try TailscaleSocket.listen(handle, address: ":\(port)")
        return VaultTailnetListener(handle: handle, listener: listener)
    }
}
