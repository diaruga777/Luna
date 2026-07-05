//
//  GoogleAuthClient.swift
//  Luna
//

import AuthenticationServices
import CryptoKit
import Foundation
import LunaStorage
import UIKit

/// Google OAuth for the YouTube Data API: sign-in, token refresh, sign-out.
public protocol GoogleAuthProviding {
    /// Whether a refresh token is stored (sign-in completed at some point).
    var isSignedIn: Bool { get }
    /// A currently valid access token, refreshing if needed. Throws when not
    /// signed in or refresh fails.
    func accessToken() async throws -> String
    /// Runs the interactive OAuth flow.
    @MainActor func signIn() async throws
    /// Forgets all tokens.
    func signOut()
}

/// PKCE OAuth against accounts.google.com with tokens in the Keychain.
/// The client ID comes from settings (`YouTubeSettings.googleClientID`).
public final class GoogleAuthClient: NSObject, GoogleAuthProviding,
    ASWebAuthenticationPresentationContextProviding {

    public static let shared = GoogleAuthClient()

    public struct AuthError: Error, CustomStringConvertible {
        public let reason: String
        public var description: String { reason }
        public init(reason: String) { self.reason = reason }
    }

    private let keychainService = "com.hsanabria.luna.google"
    private let keychainAccount = "oauth-tokens"
    private let scope = "https://www.googleapis.com/auth/youtube"

    private struct StoredTokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiry: Date
    }

    public var isSignedIn: Bool { loadTokens() != nil }

    public func accessToken() async throws -> String {
        guard var tokens = loadTokens() else {
            throw AuthError(reason: "Sign in to YouTube in Settings first.")
        }
        if tokens.expiry > Date().addingTimeInterval(60) {
            return tokens.accessToken
        }
        let refreshed = try await requestToken(parameters: [
            "client_id": YouTubeSettings.googleClientID,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token",
        ])
        tokens.accessToken = refreshed.accessToken
        tokens.expiry = refreshed.expiry
        saveTokens(tokens)
        return tokens.accessToken
    }

    @MainActor
    public func signIn() async throws {
        let clientID = YouTubeSettings.googleClientID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw AuthError(reason: "Enter your Google OAuth client ID in Settings first.")
        }
        guard let scheme = Self.redirectScheme(forClientID: clientID) else {
            throw AuthError(reason: "That doesn't look like an iOS OAuth client ID.")
        }
        let redirectURI = "\(scheme):/oauthredirect"

        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.codeChallenge(forVerifier: verifier)

        var authComponents = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        authComponents?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authURL = authComponents?.url else {
            throw AuthError(reason: "Couldn't build the sign-in URL.")
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL, callbackURLScheme: scheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? AuthError(reason: "Sign-in cancelled."))
                }
            }
            session.presentationContextProvider = self
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw AuthError(reason: "Google didn't return an authorization code.")
        }

        let response = try await requestToken(parameters: [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])
        guard let refreshToken = response.refreshToken else {
            throw AuthError(reason: "Google didn't return a refresh token.")
        }
        saveTokens(StoredTokens(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiry: response.expiry))
    }

    public func signOut() {
        CredentialKeychain.delete(service: keychainService, account: keychainAccount)
    }

    // MARK: - Token endpoint

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiry: Date
    }

    private func requestToken(parameters: [String: String]) async throws -> TokenResponse {
        // URL(string:) of a constant endpoint never fails.
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .map { key, value in
                let escaped = value.addingPercentEncoding(
                    withAllowedCharacters: .alphanumerics) ?? value
                return "\(key)=\(escaped)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError(reason: "Token request failed: \(String(decoding: data, as: UTF8.self).prefix(200))")
        }

        struct Wire: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Double

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        return TokenResponse(
            accessToken: wire.accessToken,
            refreshToken: wire.refreshToken,
            expiry: Date().addingTimeInterval(wire.expiresIn))
    }

    // MARK: - PKCE helpers

    /// iOS clients redirect to the reversed client ID
    /// ("123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc").
    public static func redirectScheme(forClientID clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        let identifier = String(clientID.dropLast(suffix.count))
        guard !identifier.isEmpty else { return nil }
        return "com.googleusercontent.apps.\(identifier)"
    }

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

    // MARK: - Keychain

    private func loadTokens() -> StoredTokens? {
        guard let data = CredentialKeychain.readData(
            service: keychainService, account: keychainAccount) else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    private func saveTokens(_ tokens: StoredTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        CredentialKeychain.write(data, service: keychainService, account: keychainAccount)
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The app is single-window; the key window is always the right anchor.
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
