//
//  PluginMailMIME.swift
//  LunaPluginExport
//

import Foundation
import LunaMailAccount
import LunaModels

/// Assembles the RFC 5322 message for a `luna.mail.send` (§6.13).
///
/// A message with no attachment is `EmailMIMEBuilder`'s own share shape, so a
/// plugin's mail reads exactly like Luna's. Attachments make it
/// `multipart/mixed` with the body first — the layout `MIMEMessage` produces
/// for the emailed EPUB, generalized to several files.
public enum PluginMailMIME {

    public static func build(_ message: PluginMailMessage, from: String) -> Data {
        guard !message.attachments.isEmpty else {
            return EmailMIMEBuilder.build(
                from: from, to: message.recipients, subject: message.subject,
                plainBody: message.text ?? "", htmlBody: message.html ?? htmlFallback(message))
        }
        let crlf = "\r\n"
        let boundary = "luna-plugin-\(UUID().uuidString)"
        var out = ""
        out += "From: <\(from)>\(crlf)"
        out += "To: \(message.recipients.joined(separator: ", "))\(crlf)"
        out += "Subject: \(MIMEHeaderEncoding.encodedHeaderText(message.subject))\(crlf)"
        out += "Date: \(MIMEHeaderEncoding.rfc5322Date())\(crlf)"
        out += "Message-ID: <\(UUID().uuidString)@luna.local>\(crlf)"
        out += "MIME-Version: 1.0\(crlf)"
        out += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\(crlf)"
        out += crlf

        out += "--\(boundary)\(crlf)"
        if let html = message.html {
            out += "Content-Type: text/html; charset=utf-8\(crlf)"
            out += "Content-Transfer-Encoding: base64\(crlf)\(crlf)"
            out += base64Wrapped(Data(html.utf8)) + crlf
        } else {
            out += "Content-Type: text/plain; charset=utf-8\(crlf)"
            out += "Content-Transfer-Encoding: base64\(crlf)\(crlf)"
            out += base64Wrapped(Data((message.text ?? "").utf8)) + crlf
        }

        for attachment in message.attachments {
            out += "--\(boundary)\(crlf)"
            out += "Content-Type: \(attachment.mime); "
                + "name=\"\(MIMEHeaderEncoding.encodedHeaderText(attachment.name))\"\(crlf)"
            out += "Content-Transfer-Encoding: base64\(crlf)"
            out += "Content-Disposition: attachment; "
                + "filename=\"\(MIMEHeaderEncoding.encodedHeaderText(attachment.name))\"\(crlf)"
            out += crlf
            out += base64Wrapped(attachment.data) + crlf
        }

        out += "--\(boundary)--\(crlf)"
        return Data(out.utf8)
    }

    /// A message that carries only plain text still needs an HTML part for
    /// `EmailMIMEBuilder`'s alternative shape. The text goes in escaped.
    static func htmlFallback(_ message: PluginMailMessage) -> String {
        let escaped = (message.text ?? "")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<html><body><p>\(escaped)</p></body></html>"
    }

    static func base64Wrapped(_ data: Data) -> String {
        data.base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn,
                      .endLineWithLineFeed])
    }
}
