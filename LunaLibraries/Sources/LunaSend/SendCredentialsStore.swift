//
//  SendCredentialsStore.swift
//  Luna
//

import Foundation
import LunaStorage

/// Holds the secret for the Boox send feature: the Send2Boox auth token.
/// (Kindle sends through the connected email account, so it needs no secret
/// here.)
public protocol SendCredentialsStoring {
    /// The stored Send2Boox auth token, if any.
    func booxToken() -> String?
    /// Stores (or, with nil/empty, deletes) the Send2Boox auth token.
    func setBooxToken(_ token: String?)
}

/// Keychain-backed credential storage. Sends always run in the main app
/// process, so no shared access group is needed. The token is migratable and
/// iCloud-Keychain synchronizable so device transfer/restore can preserve it.
public final class KeychainSendCredentialsStore: SendCredentialsStoring {

    public static let shared = KeychainSendCredentialsStore()

    private let booxService = "com.hsanabria.luna.boox"
    private let booxAccount = "boox-token"

    public func booxToken() -> String? {
        CredentialKeychain.read(service: booxService, account: booxAccount)
    }

    public func setBooxToken(_ token: String?) {
        CredentialKeychain.write(token, service: booxService, account: booxAccount)
    }
}

/// In-memory stand-in for tests.
public final class InMemorySendCredentialsStore: SendCredentialsStoring {
    private var token: String?

    public init() {}

    public func booxToken() -> String? { token }
    public func setBooxToken(_ newToken: String?) {
        token = (newToken?.isEmpty ?? true) ? nil : newToken
    }
}
