//
//  EmailMIMEBuilder.swift
//  LunaMailAccount
//

import Foundation

/// An inline image referenced from the HTML body by `cid:<contentID>`.
public struct InlineImage: Equatable {
    public let contentID: String
    public let mimeType: String
    public let data: Data
    public init(contentID: String, mimeType: String, data: Data) {
        self.contentID = contentID
        self.mimeType = mimeType
        self.data = data
    }
}

/// Assembles a full RFC 5322 message for a Luna share:
///
/// ```
/// multipart/related
///   multipart/alternative
///     text/plain      (readable fallback)
///     text/html       (the rich body, images via cid:)
///   image/*           (each inline image, Content-ID)
/// ```
///
/// Line endings are CRLF throughout; dot-stuffing is the SMTP layer's job.
/// Custom headers (notably `X-Luna-Share`) are emitted verbatim.
public enum EmailMIMEBuilder {

    public static func build(
        from: String,
        to: [String],
        subject: String,
        plainBody: String,
        htmlBody: String,
        inlineImages: [InlineImage] = [],
        headers: [String: String] = [:]
    ) -> Data {
        let crlf = "\r\n"
        let related = "luna-rel-\(UUID().uuidString)"
        let alternative = "luna-alt-\(UUID().uuidString)"

        var out = ""
        out += "From: \(from)\(crlf)"
        out += "To: \(to.joined(separator: ", "))\(crlf)"
        out += "Subject: \(encodedHeaderText(subject))\(crlf)"
        out += "Date: \(rfc5322Date())\(crlf)"
        out += "Message-ID: <\(UUID().uuidString)@luna.local>\(crlf)"
        out += "MIME-Version: 1.0\(crlf)"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            out += "\(key): \(value)\(crlf)"
        }
        out += "Content-Type: multipart/related; boundary=\"\(related)\"\(crlf)"
        out += crlf

        // multipart/alternative (plain + html)
        out += "--\(related)\(crlf)"
        out += "Content-Type: multipart/alternative; boundary=\"\(alternative)\"\(crlf)\(crlf)"

        out += "--\(alternative)\(crlf)"
        out += "Content-Type: text/plain; charset=utf-8\(crlf)"
        out += "Content-Transfer-Encoding: base64\(crlf)\(crlf)"
        out += base64Wrapped(plainBody) + crlf

        out += "--\(alternative)\(crlf)"
        out += "Content-Type: text/html; charset=utf-8\(crlf)"
        out += "Content-Transfer-Encoding: base64\(crlf)\(crlf)"
        out += base64Wrapped(htmlBody) + crlf

        out += "--\(alternative)--\(crlf)"

        // Inline images
        for image in inlineImages {
            out += "--\(related)\(crlf)"
            out += "Content-Type: \(image.mimeType)\(crlf)"
            out += "Content-Transfer-Encoding: base64\(crlf)"
            out += "Content-ID: <\(image.contentID)>\(crlf)"
            out += "Content-Disposition: inline\(crlf)\(crlf)"
            out += image.data.base64EncodedString(
                options: [.lineLength76Characters, .endLineWithCarriageReturn,
                          .endLineWithLineFeed]) + crlf
        }

        out += "--\(related)--\(crlf)"
        return Data(out.utf8)
    }

    // MARK: - Helpers

    /// Base64 of UTF-8 text, wrapped to 76-char CRLF lines (7-bit safe body).
    static func base64Wrapped(_ text: String) -> String {
        Data(text.utf8).base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn,
                      .endLineWithLineFeed])
    }

    /// RFC 2047 B-encoding for header text that isn't plain printable ASCII.
    static func encodedHeaderText(_ text: String) -> String {
        let isPlainASCII = text.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
        if isPlainASCII { return text }
        return "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
    }

    static func rfc5322Date(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
