//
//  FriendLink.swift
//  Lune
//

import Foundation

/// Encodes an identity card as a `lunereader://friend?...` URL (shared as a
/// link or rendered as a QR code) and parses it back. The same URL is handled
/// by the in-app scanner, the system camera, and tapped links.
public enum FriendLink {

    public static let scheme = "lunereader"
    public static let host = "friend"

    public static func url(for card: IdentityCard) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items = [
            URLQueryItem(name: "u", value: card.uuid.uuidString),
            URLQueryItem(name: "n", value: card.username),
            URLQueryItem(name: "ke", value: base64URL(card.encryptionPublicKey)),
            URLQueryItem(name: "ks", value: base64URL(card.signingPublicKey)),
        ]
        if let email = card.email { items.append(URLQueryItem(name: "e", value: email)) }
        if let phone = card.phone { items.append(URLQueryItem(name: "p", value: phone)) }
        components.queryItems = items
        return components.url
    }

    /// Parses a friend URL; nil for anything malformed (wrong scheme/host,
    /// missing or invalid fields, oversized username).
    public static func card(from url: URL) -> IdentityCard? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host,
              let items = components.queryItems
        else { return nil }

        var values: [String: String] = [:]
        for item in items {
            if let value = item.value { values[item.name] = value }
        }

        guard let uuid = values["u"].flatMap(UUID.init(uuidString:)),
              let username = values["n"].flatMap(ProfileValidation.normalizedUsername),
              let encryptionKey = values["ke"].flatMap(dataFromBase64URL),
              let signingKey = values["ks"].flatMap(dataFromBase64URL),
              encryptionKey.count == 32, signingKey.count == 32
        else { return nil }

        return IdentityCard(
            uuid: uuid,
            username: username,
            email: ProfileValidation.normalizedContactField(values["e"]),
            phone: ProfileValidation.normalizedContactField(values["p"]),
            encryptionPublicKey: encryptionKey,
            signingPublicKey: signingKey)
    }

    // MARK: - base64url

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func dataFromBase64URL(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
