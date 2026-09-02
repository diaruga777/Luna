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
        out += bodyPart(message, crlf: crlf)

        for attachment in message.attachments {
            let name = quotedParameter(MIMEHeaderEncoding.encodedHeaderText(attachment.name))
            out += "--\(boundary)\(crlf)"
            out += "Content-Type: \(attachment.mime); name=\"\(name)\"\(crlf)"
            out += "Content-Transfer-Encoding: base64\(crlf)"
            out += "Content-Disposition: attachment; filename=\"\(name)\"\(crlf)"
            out += crlf
            out += base64Wrapped(attachment.data) + crlf
        }

        out += "--\(boundary)--\(crlf)"
        return Data(out.utf8)
    }

    /// The body of an attachment-carrying message.
    ///
    /// Both bodies become a nested `multipart/alternative`, the same shape
    /// `EmailMIMEBuilder` gives a message with no attachment: a client that
    /// shows plain text must not lose the text alternative merely because a
    /// file rode along.
    private static func bodyPart(_ message: PluginMailMessage, crlf: String) -> String {
        guard let html = message.html, let text = message.text, !text.isEmpty else {
            let body = message.html ?? message.text ?? ""
            let type = message.html == nil ? "text/plain" : "text/html"
            return "Content-Type: \(type); charset=utf-8\(crlf)"
                + "Content-Transfer-Encoding: base64\(crlf)\(crlf)"
                + base64Wrapped(Data(body.utf8)) + crlf
        }
        let inner = "luna-plugin-alt-\(UUID().uuidString)"
        var out = "Content-Type: multipart/alternative; boundary=\"\(inner)\"\(crlf)\(crlf)"
        out += "--\(inner)\(crlf)"
        out += "Content-Type: text/plain; charset=utf-8\(crlf)"
        out += "Content-Transfer-Encoding: base64\(crlf)\(crlf)"
        out += base64Wrapped(Data(text.utf8)) + crlf
        out += "--\(inner)\(crlf)"
        out += "Content-Type: text/html; charset=utf-8\(crlf)"
        out += "Content-Transfer-Encoding: base64\(crlf)\(crlf)"
        out += base64Wrapped(Data(html.utf8)) + crlf
        out += "--\(inner)--\(crlf)"
        return out
    }

    /// A quoted MIME parameter cannot carry a bare quote or a line break, and
    /// the plugin chooses the attachment name.
    static func quotedParameter(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
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
