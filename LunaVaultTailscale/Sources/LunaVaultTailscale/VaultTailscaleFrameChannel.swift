import Darwin
import Foundation
import LunaVaultBackend

/// A `VaultMacFrameChannel` over a connected socket file descriptor, as
/// returned by `TailscaleSocket.dial` and `TailscaleSocket.accept`. The wire
/// format matches `VaultMacNWFrameChannel` exactly: a 4-byte big-endian frame
/// length followed by the frame.
///
/// Task cancellation and `close()` shut the socket down, which wakes any
/// blocked read or write; the descriptor itself is closed only on
/// deinitialization so a concurrent operation can never touch a reused
/// descriptor number.
public final class VaultTailscaleFrameChannel: VaultMacFrameChannel, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false
    private let readQueue = DispatchQueue(label: "com.hsanabria.luna.vault.tailscale-channel.read")
    private let writeQueue = DispatchQueue(label: "com.hsanabria.luna.vault.tailscale-channel.write")
    private static let pollTickMilliseconds: Int32 = 250

    public init(fileDescriptor: Int32) {
        self.fd = fileDescriptor
        // A write after the peer closes raises SIGPIPE by default, which
        // kills the process instead of failing the write. SO_NOSIGPIPE
        // turns that into a normal EPIPE, which blockingWrite already
        // handles through its errno path. Covers both the dial path
        // (VaultTailscaleMacConnector) and the accept path
        // (VaultTailnetListener): both construct a channel only here.
        var noSigPipe: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE,
                  &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        VaultTailnetLog.channel.debug("Channel opened. fd=\(fileDescriptor, privacy: .public)")
    }

    deinit {
        Darwin.close(fd)
    }

    public func close() {
        let shouldShutDown: Bool = lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        if shouldShutDown {
            VaultTailnetLog.channel.debug("Channel closed. fd=\(self.fd, privacy: .public)")
            shutdown(fd, SHUT_RDWR)
        }
    }

    private var closed: Bool { lock.withLock { isClosed } }

    public func send(_ frame: Data) async throws {
        guard frame.count > 0, frame.count <= VaultMacProtocol.maximumFrameBytes + 1024 else {
            throw VaultMacProtocolError.frameTooLarge
        }
        var size = UInt32(frame.count).bigEndian
        var framed = Data(bytes: &size, count: 4)
        framed.append(frame)
        let payload = framed
        do {
            try await run(on: writeQueue) { try self.blockingWrite(payload) }
            VaultTailnetLog.channel.debug("Sent frame. fd=\(self.fd, privacy: .public) bytes=\(frame.count, privacy: .public)")
        } catch {
            VaultTailnetLog.channel.error("Send failed. fd=\(self.fd, privacy: .public) bytes=\(frame.count, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    public func receive() async throws -> Data {
        do {
            let header = try await run(on: readQueue) { try self.blockingRead(4) }
            let size = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            guard size > 0, size <= UInt32(VaultMacProtocol.maximumFrameBytes + 1024) else {
                VaultTailnetLog.channel.error("Received invalid frame length \(size, privacy: .public). fd=\(self.fd, privacy: .public)")
                throw VaultMacProtocolError.frameTooLarge
            }
            let frame = try await run(on: readQueue) { try self.blockingRead(Int(size)) }
            VaultTailnetLog.channel.debug("Received frame. fd=\(self.fd, privacy: .public) bytes=\(frame.count, privacy: .public)")
            return frame
        } catch VaultMacProtocolError.frameTooLarge {
            throw VaultMacProtocolError.frameTooLarge
        } catch {
            VaultTailnetLog.channel.error("Receive failed. fd=\(self.fd, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func run<T: Sendable>(on queue: DispatchQueue,
                                  _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try operation() })
                }
            }
        }, onCancel: {
            close()
        })
    }

    private func blockingRead(_ count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(count, 1 << 16))
        while result.count < count {
            try waitUntilReady(events: Int16(POLLIN))
            let wanted = min(count - result.count, buffer.count)
            let readCount = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(fd, pointer.baseAddress, wanted)
            }
            if readCount > 0 {
                result.append(contentsOf: buffer[0..<readCount])
            } else if readCount == 0 {
                throw VaultMacProtocolError.unavailable
            } else if errno != EINTR && errno != EAGAIN {
                throw VaultMacProtocolError.unavailable
            }
        }
        return result
    }

    private func blockingWrite(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { throw VaultMacProtocolError.invalidFrame }
            while offset < data.count {
                try waitUntilReady(events: Int16(POLLOUT))
                let written = Darwin.write(fd, base + offset, data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno != EINTR && errno != EAGAIN {
                    throw VaultMacProtocolError.unavailable
                }
            }
        }
    }

    /// Polls in short ticks so `close()` from another thread terminates a
    /// blocked operation within one tick even when the peer stays silent.
    private func waitUntilReady(events: Int16) throws {
        while true {
            if closed { throw VaultMacProtocolError.unavailable }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Self.pollTickMilliseconds)
            if closed { throw VaultMacProtocolError.unavailable }
            if result > 0 {
                if (descriptor.revents & Int16(POLLNVAL)) != 0 {
                    throw VaultMacProtocolError.unavailable
                }
                return
            }
            if result < 0, errno != EINTR {
                throw VaultMacProtocolError.unavailable
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
