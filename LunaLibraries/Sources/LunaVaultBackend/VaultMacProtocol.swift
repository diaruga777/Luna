import CryptoKit
import Foundation
import LunaVaultModels

/// The application protocol used between the Vault iPhone host and its paired
/// Mac. Tailscale, a LAN address, and Bonjour are deliberately absent from the
/// authenticated identity: they are only ways to reach the same peer.
public enum VaultMacProtocol {
    public static let version: UInt16 = 1
    public static let maximumFrameBytes = 8 * 1024 * 1024
}

public enum VaultMacOperation: String, Codable, Sendable {
    case putChunk
    case readRange
    case delete
}

public struct VaultMacRequest: Codable, Equatable, Sendable {
    public let operation: VaultMacOperation
    public let objectID: VaultObjectID
    public let revision: VaultRevision?
    public let expectedRevision: UUID?
    public let chunkIndex: UInt32?
    public let totalChunks: UInt32?
    public let offset: UInt64?
    public let length: UInt64?
    public let idempotencyKey: String
    /// This is always an encrypted frame/chunk. There is intentionally no
    /// filename, content type, plaintext metadata, or root-key field.
    public let ciphertext: Data?

    public init(
        operation: VaultMacOperation,
        objectID: VaultObjectID,
        revision: VaultRevision? = nil,
        expectedRevision: UUID? = nil,
        chunkIndex: UInt32? = nil,
        totalChunks: UInt32? = nil,
        offset: UInt64? = nil,
        length: UInt64? = nil,
        idempotencyKey: String,
        ciphertext: Data? = nil
    ) {
        self.operation = operation
        self.objectID = objectID
        self.revision = revision
        self.expectedRevision = expectedRevision
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
        self.offset = offset
        self.length = length
        self.idempotencyKey = idempotencyKey
        self.ciphertext = ciphertext
    }

    public func validated() throws -> VaultMacRequest {
        guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 256 else {
            throw VaultMacProtocolError.invalidRequest
        }
        switch operation {
        case .putChunk:
            guard let revision, let chunkIndex, let totalChunks,
                  totalChunks > 0, chunkIndex < totalChunks,
                  let ciphertext, !ciphertext.isEmpty,
                  ciphertext.count <= VaultMacProtocol.maximumFrameBytes else {
                throw VaultMacProtocolError.invalidRequest
            }
            _ = revision
        case .readRange:
            guard let offset, let length,
                  offset <= UInt64.max - length,
                  length <= UInt64(VaultMacProtocol.maximumFrameBytes) else {
                throw VaultMacProtocolError.invalidRequest
            }
        case .delete:
            break
        }
        return self
    }
}

public enum VaultMacResponseStatus: String, Codable, Sendable {
    case accepted
    case partial
    case conflict
    case notFound
    case invalid
    case failed
}

public struct VaultMacResponse: Codable, Equatable, Sendable {
    public let status: VaultMacResponseStatus
    public let objectID: VaultObjectID
    public let currentRevision: UUID?
    public let receivedChunks: [UInt32]
    public let ciphertext: Data?
    public let message: String?

    public init(
        status: VaultMacResponseStatus,
        objectID: VaultObjectID,
        currentRevision: UUID? = nil,
        receivedChunks: [UInt32] = [],
        ciphertext: Data? = nil,
        message: String? = nil
    ) {
        self.status = status
        self.objectID = objectID
        self.currentRevision = currentRevision
        self.receivedChunks = receivedChunks.sorted()
        self.ciphertext = ciphertext
        self.message = message
    }
}

public struct VaultMacPairingSecret: Codable, Hashable, Sendable {
    public let rawValue: Data

    public init(rawValue: Data) throws {
        guard rawValue.count == 32 else { throw VaultMacProtocolError.invalidSecret }
        self.rawValue = rawValue
    }

    public init(base64Encoded value: String) throws {
        guard let data = Data(base64Encoded: value) else {
            throw VaultMacProtocolError.invalidSecret
        }
        try self.init(rawValue: data)
    }

    public var base64Encoded: String { rawValue.base64EncodedString() }
}

public struct VaultMacPairingChallenge: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let nonce: Data
    public let serverBinding: Data

    public init(sessionID: UUID = UUID(), nonce: Data, serverBinding: Data) throws {
        guard nonce.count >= 16, nonce.count <= 64, !serverBinding.isEmpty else {
            throw VaultMacProtocolError.invalidChallenge
        }
        self.sessionID = sessionID
        self.nonce = nonce
        self.serverBinding = serverBinding
    }

    public func proof(using secret: VaultMacPairingSecret) -> Data {
        HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: secret.rawValue))
            .withUnsafeBytes { Data($0) }
    }

    public func verify(_ response: VaultMacPairingResponse, using secret: VaultMacPairingSecret) throws {
        guard response.sessionID == sessionID, response.proof == proof(using: secret) else {
            throw VaultMacProtocolError.authenticationFailed
        }
    }

    fileprivate var transcript: Data {
        var data = Data("LunaVault-Mac-pair-v1".utf8)
        data.append(sessionID.uuidData)
        data.append(contentsOf: nonce)
        data.append(contentsOf: serverBinding)
        return data
    }
}

public struct VaultMacPairingResponse: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let proof: Data

    public init(sessionID: UUID, proof: Data) {
        self.sessionID = sessionID
        self.proof = proof
    }
}

public enum VaultMacProtocolError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidSecret
    case invalidChallenge
    case invalidFrame
    case wrongProtocolVersion
    case wrongSession
    case replayedFrame
    case authenticationFailed
    case sequenceOverflow
    case frameTooLarge
    case conflictingRevision
}

/// A compact, authenticated envelope used after pairing. TCP/Tailscale is
/// ordered but not trusted; the sequence number prevents replay and the MAC
/// binds the session and payload to the paired secret. Payloads themselves are
/// JSON request/response records whose data field is already CryptoKit
/// ciphertext.
public struct VaultMacAuthenticatedFrame: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let sessionID: UUID
    public let sequence: UInt64
    public let payload: Data
    public let tag: Data

    public init(protocolVersion: UInt16 = VaultMacProtocol.version, sessionID: UUID, sequence: UInt64, payload: Data, tag: Data) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.sequence = sequence
        self.payload = payload
        self.tag = tag
    }

    public static func seal(payload: Data, sessionID: UUID, sequence: UInt64, secret: VaultMacPairingSecret) throws -> Self {
        guard payload.count <= VaultMacProtocol.maximumFrameBytes else { throw VaultMacProtocolError.frameTooLarge }
        let material = authenticationMaterial(sessionID: sessionID, sequence: sequence, payload: payload)
        let tag = HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: secret.rawValue))
            .withUnsafeBytes { Data($0) }
        return Self(sessionID: sessionID, sequence: sequence, payload: payload, tag: tag)
    }

    public func open(using secret: VaultMacPairingSecret, expectedSessionID: UUID) throws -> Data {
        guard protocolVersion == VaultMacProtocol.version else { throw VaultMacProtocolError.wrongProtocolVersion }
        guard sessionID == expectedSessionID else { throw VaultMacProtocolError.wrongSession }
        guard payload.count <= VaultMacProtocol.maximumFrameBytes else { throw VaultMacProtocolError.frameTooLarge }
        let material = Self.authenticationMaterial(sessionID: sessionID, sequence: sequence, payload: payload)
        let expected = HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: secret.rawValue))
            .withUnsafeBytes { Data($0) }
        guard expected == tag else { throw VaultMacProtocolError.authenticationFailed }
        return payload
    }

    private static func authenticationMaterial(sessionID: UUID, sequence: UInt64, payload: Data) -> Data {
        var data = Data("LunaVault-Mac-frame-v1".utf8)
        data.append(sessionID.uuidData)
        var bigEndian = sequence.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: payload)
        return data
    }
}

/// Stateful guard used by both the iPhone client and Mac service. Frames are
/// accepted strictly once and in order; a duplicate or out-of-order frame is
/// never handed to storage.
public final class VaultMacReplayGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReceived: UInt64 = 0
    private let secret: VaultMacPairingSecret
    private let sessionID: UUID

    public init(secret: VaultMacPairingSecret, sessionID: UUID) {
        self.secret = secret
        self.sessionID = sessionID
    }

    public func open(_ frame: VaultMacAuthenticatedFrame) throws -> Data {
        try lock.withLock {
            guard frame.sequence > lastReceived else { throw VaultMacProtocolError.replayedFrame }
            let payload = try frame.open(using: secret, expectedSessionID: sessionID)
            lastReceived = frame.sequence
            return payload
        }
    }
}

public final class VaultMacSendSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence: UInt64 = 1
    private let secret: VaultMacPairingSecret
    private let sessionID: UUID

    public init(secret: VaultMacPairingSecret, sessionID: UUID) {
        self.secret = secret
        self.sessionID = sessionID
    }

    public func seal(_ payload: Data) throws -> VaultMacAuthenticatedFrame {
        try lock.withLock {
            guard nextSequence < UInt64.max else { throw VaultMacProtocolError.sequenceOverflow }
            let frame = try VaultMacAuthenticatedFrame.seal(payload: payload, sessionID: sessionID, sequence: nextSequence, secret: secret)
            nextSequence += 1
            return frame
        }
    }
}

public protocol VaultMacFrameChannel: Sendable {
    func send(_ frame: Data) async throws
    func receive() async throws -> Data
    func close()
}

public struct VaultMacDiscoveryRecord: Codable, Equatable, Sendable {
    public enum Reachability: String, Codable, Sendable { case tailscale, lanBonjour }
    public let displayName: String
    public let endpoint: String
    public let port: UInt16
    public let reachability: Reachability
    public let certificateBinding: Data

    public init(displayName: String, endpoint: String, port: UInt16, reachability: Reachability, certificateBinding: Data) {
        self.displayName = displayName
        self.endpoint = endpoint
        self.port = port
        self.reachability = reachability
        self.certificateBinding = certificateBinding
    }
}

public struct VaultMacChunkPlan: Equatable, Sendable {
    public let chunkSize: Int
    public let totalChunks: UInt32

    public init(byteCount: Int, chunkSize: Int = 4 * 1024 * 1024) throws {
        guard byteCount >= 0, chunkSize > 0 else { throw VaultMacProtocolError.invalidRequest }
        let count = max(1, (byteCount + chunkSize - 1) / chunkSize)
        guard count <= Int(UInt32.max) else { throw VaultMacProtocolError.frameTooLarge }
        self.chunkSize = chunkSize
        self.totalChunks = UInt32(count)
    }

    public func range(for index: UInt32, byteCount: Int) throws -> Range<Int> {
        guard index < totalChunks, byteCount >= 0 else { throw VaultMacProtocolError.invalidRequest }
        let lower = Int(index) * chunkSize
        return lower..<min(byteCount, lower + chunkSize)
    }
}

public enum VaultMacRequestFactory {
    public static func idempotencyKey(objectID: VaultObjectID, revision: UUID, chunkIndex: UInt32) -> String {
        var data = Data("LunaVault-Mac-put-v1".utf8)
        data.append(objectID.rawValue.uuidData)
        data.append(revision.uuidData)
        var bigEndian = chunkIndex.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension UUID {
    var uuidData: Data {
        var uuid = uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
