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

    /// Yields one entry per inbound connection. A single `tailscale_accept`
    /// failure retries with backoff instead of ending the stream: a caller
    /// that owns a second, independent listener (the companion CLI's
    /// `--bind-host` LAN listener) would otherwise tear it down too when it
    /// treats the tailnet stream ending as fatal. `poll`'s own failure still
    /// ends the stream — it means the listener descriptor itself is bad.
    public func connections() -> AsyncThrowingStream<VaultTailnetAcceptedConnection, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in self?.close() }
            queue.async { [self] in
                var consecutiveAcceptFailures = 0
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
                        consecutiveAcceptFailures = 0
                        VaultTailnetLog.listener.info("Accepted tailnet connection from \(remote ?? "unknown", privacy: .public) fd=\(fd, privacy: .public)")
                        continuation.yield(VaultTailnetAcceptedConnection(
                            channel: VaultTailscaleFrameChannel(fileDescriptor: fd),
                            peer: remote ?? "unknown"))
                    } catch {
                        consecutiveAcceptFailures += 1
                        let backoff = Self.acceptRetryBackoff(afterFailureCount: consecutiveAcceptFailures)
                        VaultTailnetLog.listener.error("Accept failed; retrying in \(backoff, privacy: .public)s. failureCount=\(consecutiveAcceptFailures, privacy: .public) error=\(String(describing: error), privacy: .public)")
                        // Sleep in poll-tick-sized slices so close() from
                        // another thread still stops the loop within one
                        // tick instead of waiting out the full backoff.
                        var remaining = backoff
                        let slice = TimeInterval(Self.pollTickMilliseconds) / 1_000
                        while remaining > 0, !closed {
                            Thread.sleep(forTimeInterval: min(slice, remaining))
                            remaining -= slice
                        }
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Exponential backoff capped at 30s, pure so it is cheap to pin without
    /// driving the poll loop.
    public static func acceptRetryBackoff(afterFailureCount count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return min(pow(2.0, Double(count - 1)), 30)
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
