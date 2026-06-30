//
//  SMTPClient.swift
//  Lune
//

import LuneEpub
import Foundation
import Network
import os

/// Byte-level connection a SMTP session runs over. The real implementation is
/// TLS over TCP (implicit TLS, port 465); tests script a mock.
public protocol SMTPTransport {
    /// Opens the connection; throws if it can't be established.
    func connect() async throws
    /// Writes raw bytes.
    func send(_ data: Data) async throws
    /// Reads one CRLF-terminated line (returned without the CRLF).
    func readLine() async throws -> String
    /// Tears the connection down; safe to call more than once.
    func close()
}

/// An SMTP failure with the server's reply attached for diagnosis.
public struct SMTPError: Error, CustomStringConvertible {
    public let step: String
    public let reply: String
    public var description: String { "SMTP \(step) failed: \(reply)" }

    public init(step: String, reply: String) {
        self.step = step
        self.reply = reply
    }
}

/// Speaks just enough ESMTP to submit one message over an authenticated
/// connection: EHLO → AUTH PLAIN (AUTH LOGIN fallback) → MAIL/RCPT/DATA → QUIT.
public final class SMTPClient {

    private let transport: SMTPTransport
    /// Hard ceiling on the whole exchange, so a stalled socket can't park a
    /// receive continuation forever (closing the transport unblocks it).
    private static let timeoutSeconds: UInt64 = 30

    public init(transport: SMTPTransport) {
        self.transport = transport
    }

    /// Submits one message. `username`/`password` authenticate; the message's
    /// own From/To headers should match `from`/`to`.
    public func submit(message: MIMEMessage, username: String, password: String) async throws {
        let watchdog = Task { [transport] in
            try? await Task.sleep(nanoseconds: Self.timeoutSeconds * 1_000_000_000)
            transport.close()
        }
        defer { watchdog.cancel() }
        try await withTaskCancellationHandler {
            try await performSubmit(message: message, username: username, password: password)
        } onCancel: {
            transport.close()
        }
    }

    private func performSubmit(message: MIMEMessage, username: String, password: String) async throws {
        defer { transport.close() }
        try await transport.connect()

        try await expect(code: "220", step: "greeting")
        try await command("EHLO lune.local", expecting: "250", step: "EHLO")
        try await authenticate(username: username, password: password)
        try await command("MAIL FROM:<\(message.from)>", expecting: "250", step: "MAIL FROM")
        try await command("RCPT TO:<\(message.to)>", expecting: "250", step: "RCPT TO")
        try await command("DATA", expecting: "354", step: "DATA")
        try await transport.send(Self.dotStuffed(message.messageData()))
        try await transport.send(Data("\r\n.\r\n".utf8))
        try await expect(code: "250", step: "message body")
        // QUIT reply is best-effort; the message is already accepted.
        try? await transport.send(Data("QUIT\r\n".utf8))
    }

    // MARK: - Auth

    private func authenticate(username: String, password: String) async throws {
        let plain = Data("\0\(username)\0\(password)".utf8).base64EncodedString()
        try await transport.send(Data("AUTH PLAIN \(plain)\r\n".utf8))
        let plainReply = try await readReply()
        if plainReply.code == "235" { return }

        // Some servers only advertise LOGIN.
        try await transport.send(Data("AUTH LOGIN\r\n".utf8))
        let loginReply = try await readReply()
        guard loginReply.code == "334" else {
            throw SMTPError(step: "AUTH", reply: plainReply.lastLine)
        }
        try await transport.send(
            Data((Data(username.utf8).base64EncodedString() + "\r\n").utf8))
        let usernameReply = try await readReply()
        guard usernameReply.code == "334" else {
            throw SMTPError(step: "AUTH LOGIN username", reply: usernameReply.lastLine)
        }
        try await transport.send(
            Data((Data(password.utf8).base64EncodedString() + "\r\n").utf8))
        let passwordReply = try await readReply()
        guard passwordReply.code == "235" else {
            throw SMTPError(step: "AUTH LOGIN password", reply: passwordReply.lastLine)
        }
    }

    // MARK: - Protocol plumbing

    private func command(_ line: String, expecting code: String, step: String) async throws {
        try await transport.send(Data((line + "\r\n").utf8))
        try await expect(code: code, step: step)
    }

    private func expect(code: String, step: String) async throws {
        let reply = try await readReply()
        guard reply.code == code else {
            throw SMTPError(step: step, reply: reply.lastLine)
        }
    }

    /// Reads a full (possibly multiline `250-…`) reply.
    private func readReply() async throws -> (code: String, lastLine: String) {
        while true {
            let line = try await transport.readLine()
            guard line.count >= 3 else {
                throw SMTPError(step: "reply parsing", reply: line)
            }
            // "250-..." marks continuation; "250 ..." (or bare "250") ends the reply.
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] != "-" {
                return (String(line.prefix(3)), line)
            }
        }
    }

    /// RFC 5321 §4.5.2: any data line starting with "." gets a "." prepended.
    public static func dotStuffed(_ data: Data) -> Data {
        var output = Data(capacity: data.count)
        var atLineStart = true
        for byte in data {
            if atLineStart && byte == UInt8(ascii: ".") {
                output.append(UInt8(ascii: "."))
            }
            output.append(byte)
            atLineStart = byte == UInt8(ascii: "\n")
        }
        return output
    }
}

/// SMTPTransport over NWConnection with implicit TLS — the port-465 submission
/// path Gmail and most providers support.
public final class TLSConnectionTransport: SMTPTransport {

    private let connection: NWConnection
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "lune.smtp.transport")

    public init(host: String, port: UInt16) {
        // Port 465 is never 0; fall back keeps the force-unwrap-free invariant.
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 465)
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tls)
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The handler runs on the connection's serial queue; the lock just
            // makes the one-shot resume guard Swift-6-clean.
            let hasResumed = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { state in
                let result: Result<Void, Error>
                switch state {
                case .ready:
                    result = .success(())
                case .failed(let error), .waiting(let error):
                    result = .failure(error)
                case .cancelled:
                    result = .failure(SMTPError(step: "connect", reply: "cancelled"))
                default:
                    return
                }
                let isFirstResume = hasResumed.withLock { resumed in
                    defer { resumed = true }
                    return !resumed
                }
                guard isFirstResume else { return }
                continuation.resume(with: result)
            }
            connection.start(queue: queue)
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func readLine() async throws -> String {
        while true {
            if let lineEnd = receiveBuffer.firstRange(of: Data("\r\n".utf8)) {
                let lineData = receiveBuffer.subdata(in: receiveBuffer.startIndex..<lineEnd.lowerBound)
                receiveBuffer.removeSubrange(receiveBuffer.startIndex..<lineEnd.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            let chunk = try await receiveChunk()
            guard !chunk.isEmpty else {
                throw SMTPError(step: "read", reply: "connection closed")
            }
            receiveBuffer.append(chunk)
        }
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }
}
