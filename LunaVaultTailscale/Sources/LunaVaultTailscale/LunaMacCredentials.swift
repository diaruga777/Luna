import Foundation
import Security
import LunaAppConfig
import LunaVaultBEP
import LunaVaultStore

/// Only authentication and the approved Mac are synchronized. Device-local
/// index cursors and caches must never become part of this value.
public struct LunaMacCredentials: Codable, Sendable {
    public struct Pairing: Codable, Sendable {
        public var deviceID: DeviceID
        public var name: String
        public var network: VaultNetworkMode
        public var addresses: [String]
        public var folderID: String
        public var folderLabel: String
        public var verifiedAt: Date
        public init(peer: VaultPeerRecord) throws {
            guard let verified = peer.lastConnectedAt else { throw LunaMacCredentialError.unverified }
            deviceID = peer.deviceID; name = peer.name; network = peer.networkMode
            addresses = peer.manualAddresses.map(\.description)
            folderID = peer.folderID; folderLabel = peer.folderLabel; verifiedAt = verified
        }
        public func peer() throws -> VaultPeerRecord {
            let parsed = try addresses.map { value -> VaultPeerAddress in
                guard let address = VaultPeerAddress(syncthingURL: value) else { throw LunaMacCredentialError.invalid }
                return address
            }
            return VaultPeerRecord(deviceID: deviceID, name: name, networkMode: network,
                manualAddresses: parsed, folderID: folderID, folderLabel: folderLabel,
                lastConnectedAt: verifiedAt)
        }
    }
    public var version = 1
    public var revision = UUID().uuidString
    public let certificate: Data
    public let privateKey: Data
    /// nil is a synchronized disconnect, while retaining the account identity.
    public var pairing: Pairing?
    public init(certificate: Data, privateKey: Data, pairing: Pairing?) {
        self.certificate = certificate; self.privateKey = privateKey; self.pairing = pairing
    }
    public var identityFingerprint: String {
        SHA256Digest.hash(certificate).map { String(format: "%02x", $0) }.joined()
    }
}

public enum LunaMacCredentialError: Error, LocalizedError {
    case keychain(OSStatus), missingAccessGroup, invalid, unverified, changedIdentity
    public var errorDescription: String? {
        switch self {
        case .keychain: return "Luna couldn’t access the shared Mac connection. Unlock this device and try again."
        case .missingAccessGroup: return "This build is missing its shared Mac Keychain configuration."
        case .invalid: return "The shared Mac connection could not be read. Try connecting again."
        case .unverified: return "Approve the connection on your Mac before sharing it."
        case .changedIdentity: return "A Mac connection arrived from iCloud. Reopen the connection screen to use it."
        }
    }
}

public protocol LunaMacCredentialStoring: Sendable {
    func load() throws -> LunaMacCredentials?
    func save(_ credentials: LunaMacCredentials) throws
}

/// One atomic synchronizable item in a dedicated group shared by the three
/// host apps. iCloud Passwords & Keychain transports the private key; it is
/// never written to preferences, CloudKit public records, or a shared URL.
public struct LunaMacKeychain: LunaMacCredentialStoring {
    private let accessGroup: String
    public init(accessGroup: String) { self.accessGroup = accessGroup }
    private var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "LunaMac.Connection.v1",
        kSecAttrAccount as String: "approved-account",
        kSecAttrAccessGroup as String: accessGroup,
        kSecAttrSynchronizable as String: true
    ] }
    public func load() throws -> LunaMacCredentials? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LunaMacCredentialError.keychain(status) }
        guard let data = result as? Data,
              let value = try? JSONDecoder().decode(LunaMacCredentials.self, from: data),
              value.version == 1, !value.certificate.isEmpty, !value.privateKey.isEmpty else {
            throw LunaMacCredentialError.invalid
        }
        return value
    }
    public func save(_ credentials: LunaMacCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            // Synchronizable items cannot use a ThisDeviceOnly accessibility.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, update as CFDictionary) }
        }
        guard status == errSecSuccess else { throw LunaMacCredentialError.keychain(status) }
    }
}

/// Materializes each synchronized certificate in its own directory because
/// the Go TLS bridge caches identities by path for the life of the process.
public final class LunaMacIdentityStore: @unchecked Sendable {
    private let root: URL
    private let credentials: any LunaMacCredentialStoring
    private let lock = NSLock()
    public init(root: URL, credentials: any LunaMacCredentialStoring) {
        self.root = root; self.credentials = credentials
    }
    public func restore() throws -> (LunaMacCredentials, LunaVaultGoTransport)? {
        lock.lock(); defer { lock.unlock() }
        guard let value = try credentials.load() else { return nil }
        let directory = root.appendingPathComponent("SharedIdentities/" + value.identityFingerprint, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        for (name, bytes) in [("cert.pem", value.certificate), ("key.pem", value.privateKey)] {
            let path = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: path.path) {
                try bytes.write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path.path)
                #endif
            }
        }
        let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: directory, requestLocalNetworkAccess: true))
        _ = try transport.identity() // Validate that certificate and private key match.
        return (value, transport)
    }
    public func publish(peer: VaultPeerRecord?, identityDirectory: URL, expectedID: DeviceID) throws {
        lock.lock(); defer { lock.unlock() }
        let existing = try credentials.load()
        let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: identityDirectory))
        guard try transport.identity() == expectedID else { throw LunaMacCredentialError.changedIdentity }
        var value = LunaMacCredentials(certificate: try Data(contentsOf: identityDirectory.appendingPathComponent("cert.pem")),
            privateKey: try Data(contentsOf: identityDirectory.appendingPathComponent("key.pem")),
            pairing: try peer.map(LunaMacCredentials.Pairing.init(peer:)))
        // Never overwrite an identity that arrived while this app was pairing.
        if let existing, existing.certificate != value.certificate { throw LunaMacCredentialError.changedIdentity }
        if let existing { value = existing; value.revision = UUID().uuidString; value.pairing = try peer.map(LunaMacCredentials.Pairing.init(peer:)) }
        try credentials.save(value)
    }
}
