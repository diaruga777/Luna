//
//  MailStream.swift
//  LunaMailTransport
//

import Foundation

/// A line/byte-oriented TLS stream over `URLSessionStreamTask`. Supports both
/// implicit TLS (secure from connect — IMAP 993, SMTP 465) and STARTTLS
/// (`startTLS()` after a plaintext greeting — SMTP 587 for iCloud), which
/// `Network.framework`'s `NWConnection` cannot do (no in-place upgrade).
///
/// Used serially by one IMAP/SMTP exchange at a time; not safe for concurrent
/// calls on the same instance.
final class MailStream {

    struct StreamError: Error, CustomStringConvertible {
        let detail: String
        var description: String { "mail stream: \(detail)" }
    }

    private let task: URLSessionStreamTask
    private let ioTimeout: TimeInterval
    private var buffer = Data()

    /// Creates and starts the stream to `host:port`. Call `startTLS()` before
    /// any I/O for implicit TLS, or after the plaintext handshake for STARTTLS.
    init(host: String, port: Int, session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.ioTimeout = timeout
        self.task = session.streamTask(withHostName: host, port: port)
        task.resume()
    }

    /// Negotiates TLS on the stream. Enqueued in order with reads/writes, so for
    /// STARTTLS it runs after the preceding plaintext exchange completes.
    func startTLS() {
        task.startSecureConnection()
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: ioTimeout) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    func writeLine(_ line: String) async throws {
        try await write(Data((line + "\r\n").utf8))
    }

    /// Reads one CRLF-terminated line (without the CRLF).
    func readLine() async throws -> String {
        while true {
            if let range = buffer.firstRange(of: Data("\r\n".utf8)) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            try await fill()
        }
    }

    /// Reads exactly `count` bytes (for IMAP literals).
    func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let data = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(data)
    }

    func close() {
        task.closeWrite()
        task.cancel()
    }

    private func fill() async throws {
        let result: (data: Data?, eof: Bool) = try await withCheckedThrowingContinuation { cont in
            task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: ioTimeout) {
                data, atEOF, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: (data, atEOF)) }
            }
        }
        if let chunk = result.data, !chunk.isEmpty {
            buffer.append(chunk)
        } else if result.eof {
            throw StreamError(detail: "connection closed")
        }
    }
}
