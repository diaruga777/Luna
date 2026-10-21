import Foundation
import Darwin
import LunaCodeCore

/// Local CLI/MCP access uses an owner-only Unix socket. Remote catalog requests
/// use Luna's existing authenticated Code channel instead of another listener.
public final class CodeMacControlServer: @unchecked Sendable {
    private let fd: Int32
    private let path: String
    private let scheduler: Task<Void, Never>
    public init(host: CodeMacHost, root: URL) throws {
        let socketPath = root.appendingPathComponent("control.sock").path
        path = socketPath
        guard path.utf8.count < 104 else { throw CodeFailure("The Code control socket path is too long.") }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CodeFailure("Couldn’t open the Code control socket.") }
        fd = descriptor
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in socketPath.withCString { source in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { strlcpy($0, source, 104) }
        } }
        unlink(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor); throw CodeFailure("Couldn’t bind the Code control socket.")
        }
        scheduler = Task { while !Task.isCancelled { await host.tick(); do { try await Task.sleep(for: .seconds(60)) } catch { return } } }
        DispatchQueue(label: "LunaCode.control").async {
            while true {
                let client = Darwin.accept(descriptor, nil, nil)
                guard client >= 0 else { break }
                var timeout = timeval(tv_sec: 190, tv_usec: 0), noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                Task.detached {
                    defer { Darwin.close(client) }
                    do {
                        guard try Self.read(client, 4) == Data("LCAT".utf8) else { return }
                        let header = try Self.read(client, 4)
                        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        guard length > 0, length <= CodeWire.maxPayloadBytes else { return }
                        let response = await host.handle(try Self.read(client, Int(length)))
                        guard response.count <= CodeWire.maxPayloadBytes else { return }
                        var count = UInt32(response.count).bigEndian
                        var frame = withUnsafeBytes(of: &count) { Data($0) }; frame.append(response)
                        try frame.withUnsafeBytes { bytes in
                            var offset = 0
                            while offset < bytes.count {
                                let written = Darwin.send(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                                guard written > 0 else { throw CodeFailure("Code control connection closed.") }; offset += written
                            }
                        }
                    } catch { }
                }
            }
        }
    }
    deinit { scheduler.cancel(); shutdown(fd, SHUT_RDWR); Darwin.close(fd); unlink(path) }
    private static func read(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let received = recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                guard received > 0 else { throw CodeFailure("Code control connection closed.") }; offset += received
            }
        }
        return data
    }
}
