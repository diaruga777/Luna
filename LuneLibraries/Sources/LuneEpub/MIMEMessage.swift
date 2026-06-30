//
//  MIMEMessage.swift
//  Lune
//

import Foundation

/// An RFC 5322 email with one file attachment, rendered as multipart/mixed.
/// Line endings are CRLF throughout (dot-stuffing is the SMTP layer's job).
public struct MIMEMessage {
    public let from: String
    public let to: String
    public let subject: String
    public let bodyText: String
    public let attachmentFileName: String
    public let attachmentMimeType: String
    public let attachmentData: Data

    public init(from: String, to: String, subject: String, bodyText: String,
                attachmentFileName: String, attachmentMimeType: String, attachmentData: Data) {
        self.from = from
        self.to = to
        self.subject = subject
        self.bodyText = bodyText
        self.attachmentFileName = attachmentFileName
        self.attachmentMimeType = attachmentMimeType
        self.attachmentData = attachmentData
    }

    /// The complete message bytes, headers through final boundary.
    public func messageData() -> Data {
        let boundary = "lune-\(UUID().uuidString)"
        let crlf = "\r\n"

        var header = ""
        header += "From: <\(from)>\(crlf)"
        header += "To: <\(to)>\(crlf)"
        header += "Subject: \(Self.encodedHeaderText(subject))\(crlf)"
        header += "Date: \(Self.rfc5322Date())\(crlf)"
        header += "Message-ID: <\(UUID().uuidString)@lune.local>\(crlf)"
        header += "MIME-Version: 1.0\(crlf)"
        header += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\(crlf)"
        header += crlf

        var body = ""
        body += "--\(boundary)\(crlf)"
        body += "Content-Type: text/plain; charset=utf-8\(crlf)"
        body += "Content-Transfer-Encoding: 8bit\(crlf)"
        body += crlf
        body += bodyText + crlf

        body += "--\(boundary)\(crlf)"
        let quotedFileName = attachmentFileName.replacingOccurrences(of: "\"", with: "'")
        body += "Content-Type: \(attachmentMimeType); name=\"\(quotedFileName)\"\(crlf)"
        body += "Content-Disposition: attachment; filename=\"\(quotedFileName)\"\(crlf)"
        body += "Content-Transfer-Encoding: base64\(crlf)"
        body += crlf
        body += attachmentData.base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        body += crlf
        body += "--\(boundary)--\(crlf)"

        return Data((header + body).utf8)
    }

    /// RFC 2047 B-encoding for header text that isn't plain printable ASCII.
    public static func encodedHeaderText(_ text: String) -> String {
        let isPlainASCII = text.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
        if isPlainASCII { return text }
        return "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
    }

    private static func rfc5322Date() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: Date())
    }
}
