//
//  MicrosoftOAuth.swift
//  LunaMailAccount
//

import Foundation
import CryptoKit

/// PKCE OAuth2 configuration + pure request building for Microsoft consumer
/// accounts (Outlook/Hotmail). Interactive sign-in (ASWebAuthenticationSession)
/// and the network calls live in the transport/UI layers; this type builds the
/// URLs and form bodies so they can be unit-tested.
///
/// The app's Azure "public client" registration id is read from the Info.plist
/// key `LunaMicrosoftClientID`; the redirect below must be registered on it.
public enum MicrosoftOAuth {

    /// Consumer (personal Microsoft account) endpoints.
    public static let authorizeEndpoint =
        "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize"
    public static let tokenEndpoint =
        "https://login.microsoftonline.com/consumers/oauth2/v2.0/token"

    /// Single custom-scheme redirect (registered once in Azure), shared by all
    /// three Luna apps.
    public static let redirectScheme = "lunamail"
    public static let redirectURI = "lunamail://auth/microsoft"

    /// Delegated Graph scopes: send, read/modify mail, manage inbox rules,
    /// plus a refresh token.
    public static let scopes = [
        "https://graph.microsoft.com/Mail.Send",
        "https://graph.microsoft.com/Mail.Read",
        "https://graph.microsoft.com/Mail.ReadWrite",
        "https://graph.microsoft.com/MailboxSettings.ReadWrite",
        "offline_access",
    ]

    /// The registered client id, or empty if the build hasn't configured one
    /// (the login flow then hides Outlook).
    public static var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "LunaMicrosoftClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - PKCE

    public struct PKCE {
        public let verifier: String
        public let challenge: String
    }

    public static func makePKCE() -> PKCE {
        let verifier = randomURLSafeString(length: 64)
        return PKCE(verifier: verifier, challenge: codeChallenge(forVerifier: verifier))
    }

    /// The authorization URL to open in `ASWebAuthenticationSession`.
    public static func authorizationURL(clientID: String, challenge: String) -> URL? {
        var components = URLComponents(string: authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components?.url
    }

    /// Form body for exchanging an authorization `code` for tokens.
    public static func tokenExchangeParameters(
        clientID: String, code: String, verifier: String
    ) -> [String: String] {
        [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "scope": scopes.joined(separator: " "),
        ]
    }

    /// Form body for refreshing an access token.
    public static func refreshParameters(clientID: String, refreshToken: String) -> [String: String] {
        [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": scopes.joined(separator: " "),
        ]
    }

    /// `application/x-www-form-urlencoded` encoding of a parameter map.
    public static func formEncode(_ parameters: [String: String]) -> Data {
        parameters
            .map { key, value in
                let escaped = value.addingPercentEncoding(
                    withAllowedCharacters: .alphanumerics) ?? value
                return "\(key)=\(escaped)"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    // MARK: - Internals

    private static func randomURLSafeString(length: Int) -> String {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    private static func codeChallenge(forVerifier verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
