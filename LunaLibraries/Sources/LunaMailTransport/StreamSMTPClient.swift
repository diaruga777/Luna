//
//  StreamSMTPClient.swift
//  LunaMailTransport
//

import Foundation
import LunaSend

/// Minimal ESMTP submission over `MailStream`. Handles both implicit TLS (465)
/// and STARTTLS (587), AUTH PLAIN with an AUTH LOGIN fallback, multiple
/// recipients, and a raw RFC 5322 message body (dot-stuffed via `SMTPClient`).
struct StreamSMTPClient {

    struct SMTPError: Error, CustomStringConvertible {
        let step: String
        let reply: String
        var description: String { "SMTP \(step) failed: \(reply)" }
    }

    let host: String
    let port: Int
    let usesSTARTTLS: Bool

    /// Connects, authenticates, and either sends `rawMessage` or (when it is
    /// nil) just proves the credentials work and quits — used by `verify`.
    func run(username: String, password: String,
             from: String? = nil, recipients: [String] = [], rawMessage: Data? = nil) async throws {
        let stream = MailStream(host: host, port: port)
        defer { stream.close() }

        if !usesSTARTTLS { stream.startTLS() }
        try await expect(stream, code: "220", step: "greeting")
        try await ehlo(stream)

        if usesSTARTTLS {
            try await command(stream, "STARTTLS", expect: "220", step: "STARTTLS")
            stream.startTLS()
            try await ehlo(stream)
        }

        try await authenticate(stream, username: username, password: password)

        guard let rawMessage else {
            try? await stream.writeLine("QUIT")   // verify-only: credentials proven
            return
        }
        guard let from, !recipients.isEmpty else {
            // A message with no sender or no recipients must fail loudly — a
            // QUIT-and-return here would report a "send" that sent nothing.
            throw SMTPError(step: "send", reply: "message missing sender or recipients")
        }

        try await command(stream, "MAIL FROM:<\(from)>", expect: "250", step: "MAIL FROM")
        for recipient in recipients {
            try await command(stream, "RCPT TO:<\(recipient)>", expect: "250", step: "RCPT TO")
        }
        try await command(stream, "DATA", expect: "354", step: "DATA")
        // Chunked so each write gets its own MailStream I/O window — one write
        // of a multi-MB share would trip the per-write timeout on slow uplinks.
        let stuffed = SMTPClient.dotStuffed(rawMessage)
        var offset = stuffed.startIndex
        while offset < stuffed.endIndex {
            let end = stuffed.index(offset, offsetBy: 128 * 1024, limitedBy: stuffed.endIndex)
                ?? stuffed.endIndex
            try await stream.write(Data(stuffed[offset..<end]))
            offset = end
        }
        try await stream.write(Data("\r\n.\r\n".utf8))
        try await expect(stream, code: "250", step: "message body")
        try? await stream.writeLine("QUIT")
    }

    // MARK: - Steps

    private func ehlo(_ stream: MailStream) async throws {
        try await command(stream, "EHLO luna.local", expect: "250", step: "EHLO")
    }

    private func authenticate(_ stream: MailStream, username: String, password: String) async throws {
        let plain = Data("\0\(username)\0\(password)".utf8).base64EncodedString()
        try await stream.writeLine("AUTH PLAIN \(plain)")
        if try await readReply(stream).code == "235" { return }

        try await stream.writeLine("AUTH LOGIN")
        let login = try await readReply(stream)
        guard login.code == "334" else {
            throw SMTPError(step: "AUTH", reply: login.lastLine)
        }
        try await stream.writeLine(Data(username.utf8).base64EncodedString())
        let user = try await readReply(stream)
        guard user.code == "334" else {
            throw SMTPError(step: "AUTH LOGIN username", reply: user.lastLine)
        }
        try await stream.writeLine(Data(password.utf8).base64EncodedString())
        let pass = try await readReply(stream)
        guard pass.code == "235" else {
            throw SMTPError(step: "AUTH LOGIN password", reply: pass.lastLine)
        }
    }

    // MARK: - Protocol plumbing

    private func command(_ stream: MailStream, _ line: String,
                         expect code: String, step: String) async throws {
        try await stream.writeLine(line)
        try await expect(stream, code: code, step: step)
    }

    private func expect(_ stream: MailStream, code: String, step: String) async throws {
        let reply = try await readReply(stream)
        guard reply.code == code else { throw SMTPError(step: step, reply: reply.lastLine) }
    }

    /// Reads a (possibly multiline `250-…`) reply, returning its code + last line.
    private func readReply(_ stream: MailStream) async throws -> (code: String, lastLine: String) {
        while true {
            let line = try await stream.readLine()
            guard line.count >= 3 else { throw SMTPError(step: "reply", reply: line) }
            let afterCode = line[line.index(line.startIndex, offsetBy: 3)...].first
            if afterCode != "-" { return (String(line.prefix(3)), line) }
        }
    }
}
