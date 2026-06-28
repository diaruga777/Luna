//
//  BooxAuthClient.swift
//  Clip
//

import Foundation

/// Onyx login is an OTP flow (email/phone → emailed code → long-lived token),
/// comparable to device pairing. The token is the durable credential.
public protocol BooxAuthenticating {
    /// Requests an OTP be sent to the email/phone (`users/sendMobileCode`).
    func requestLoginCode(identity: String) async throws
    /// Exchanges the OTP for a token (`users/signupByPhoneOrEmail`).
    func login(identity: String, code: String) async throws -> String
}

/// Production auth client against the Send2Boox API.
public final class BooxAuthClient: BooxAuthenticating {

    private let api: BooxAPIClient

    public init(host: String, session: URLSession = .shared) {
        self.api = BooxAPIClient(host: host, session: session)
    }

    public func requestLoginCode(identity: String) async throws {
        try await api.send(path: "users/sendMobileCode", body: ["mobi": identity])
    }

    public func login(identity: String, code: String) async throws -> String {
        let data = try await api.value(
            path: "users/signupByPhoneOrEmail",
            body: ["mobi": identity, "code": code],
            as: BooxLoginData.self)
        return data.token
    }
}
