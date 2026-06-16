//
//  OSSRequestSigner.swift
//  Clip
//

import Foundation
import CryptoKit

/// Signs Alibaba Cloud OSS requests with the V1 (HMAC-SHA1) scheme, using the
/// temporary STS credentials Send2Boox hands out. The Boox upload is a single
/// virtual-hosted `PUT` of the object, so only that case is modeled.
///
/// Reference: OSS "Add a signature to the Authorization header" — StringToSign =
/// VERB\nContent-MD5\nContent-Type\nDate\nCanonicalizedOSSHeaders + CanonicalizedResource.
struct OSSRequestSigner {

    let accessKeyId: String
    let accessKeySecret: String
    let securityToken: String

    /// Everything needed to issue the signed PUT.
    struct SignedPut {
        let url: URL
        /// Header name → value (Authorization, Date, Content-Type, x-oss-security-token).
        let headers: [String: String]
    }

    /// Signs a PUT of `data`-typed `contentType` to `objectKey` in `bucket` on
    /// `endpointHost` (e.g. `oss-eu-central-1.aliyuncs.com`), at `date`.
    func signPut(
        bucket: String, endpointHost: String, objectKey: String,
        contentType: String, date: Date
    ) -> SignedPut? {
        let host = Self.strippedHost(endpointHost)
        guard let url = URL(string: "https://\(bucket).\(host)/\(objectKey)") else { return nil }

        let dateString = Self.rfc1123(date)
        let ossHeaders = ["x-oss-security-token": securityToken]
        let canonicalizedOSSHeaders = ossHeaders.keys.sorted()
            .map { "\($0.lowercased()):\(ossHeaders[$0] ?? "")\n" }
            .joined()
        let canonicalizedResource = "/\(bucket)/\(objectKey)"

        let stringToSign = Self.stringToSign(
            method: "PUT", contentMD5: "", contentType: contentType, date: dateString,
            canonicalizedOSSHeaders: canonicalizedOSSHeaders,
            canonicalizedResource: canonicalizedResource)
        let signature = Self.hmacSHA1Base64(key: accessKeySecret, message: stringToSign)

        return SignedPut(url: url, headers: [
            "Authorization": "OSS \(accessKeyId):\(signature)",
            "Date": dateString,
            "Content-Type": contentType,
            "x-oss-security-token": securityToken,
        ])
    }

    /// Assembles the OSS V1 StringToSign. Pure, for testing the canonicalization.
    static func stringToSign(
        method: String, contentMD5: String, contentType: String, date: String,
        canonicalizedOSSHeaders: String, canonicalizedResource: String
    ) -> String {
        "\(method)\n\(contentMD5)\n\(contentType)\n\(date)\n\(canonicalizedOSSHeaders)\(canonicalizedResource)"
    }

    /// Base64 of HMAC-SHA1(key, message) — OSS V1 uses SHA-1.
    static func hmacSHA1Base64(key: String, message: String) -> String {
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let code = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(message.utf8), using: symmetricKey)
        return Data(code).base64EncodedString()
    }

    /// RFC 1123 / RFC 822 date in GMT, as OSS expects in the `Date` header.
    static func rfc1123(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    /// Strips any scheme/trailing slash from a configured endpoint so it can be
    /// used as a virtual-hosted host component.
    private static func strippedHost(_ endpoint: String) -> String {
        var host = endpoint
        if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
        if host.hasSuffix("/") { host.removeLast() }
        return host
    }
}
