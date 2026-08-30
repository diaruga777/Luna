import CryptoKit
import Foundation
import LunaVaultCrypto
import LunaVaultModels
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum VaultMacProtocol {
    public static let version: UInt16 = 2
    public static let maximumFrameBytes = 8 * 1024 * 1024
    /// Raw ciphertext carried inside request/response JSON. Keeping this at
    /// 4 MiB leaves room for both inner and outer base64 expansion beneath the
    /// authenticated 8 MiB frame ceiling.
    public static let maximumTransferBytes = 4 * 1024 * 1024
    public static let maximumObjectBytes: UInt64 = 100 * 1024 * 1024 * 1024
    // A peer cannot force the companion to retain an unbounded chunk-index
    // array in the encrypted manifest or in a partial response. The normal
    // client uses ~25k chunks for a 100 GiB object; 65,536 leaves headroom for
    // resumable uploads while keeping the sorted index list well below the
    // authenticated frame ceiling even with JSON/base64 expansion.
    public static let maximumChunks: UInt32 = 65_536
    public static let serviceType = "_lunavault._tcp"
}

public enum VaultMacProtocolError: Error, Equatable, Sendable {
    case invalidRequest, invalidSecret, invalidChallenge, invalidFrame
    case wrongProtocolVersion, wrongSession, wrongDirection
    case replayedFrame, outOfOrderFrame, authenticationFailed
    case sequenceOverflow, frameTooLarge, objectTooLarge, conflictingRevision
    case expired, revoked, pairingAlreadyConsumed, unconfirmedServerIdentity
    case invalidEndpoint, unavailable
}

public enum VaultMacOperation: String, Codable, Sendable { case putChunk, stat, readRange, delete }

public struct VaultMacRequest: Codable, Equatable, Sendable {
    public let operation: VaultMacOperation
    public let objectID: VaultObjectID
    public let revision: VaultRevision?
    public let expectedRevision: UUID?
    public let chunkIndex: UInt32?
    public let totalChunks: UInt32?
    public let totalCiphertextBytes: UInt64?
    public let offset: UInt64?
    public let length: UInt64?
    public let idempotencyKey: String
    /// An already encrypted Vault envelope or byte range. There is no filename,
    /// MIME type, plaintext metadata, index term, or root-key field.
    public let ciphertext: Data?
    public let objectKind: VaultRemoteObjectKind?
    public let payloadGeneration: String?

    public init(operation: VaultMacOperation, objectID: VaultObjectID,
                revision: VaultRevision? = nil, expectedRevision: UUID? = nil,
                chunkIndex: UInt32? = nil, totalChunks: UInt32? = nil,
                totalCiphertextBytes: UInt64? = nil, offset: UInt64? = nil,
                length: UInt64? = nil, idempotencyKey: String,
                ciphertext: Data? = nil, objectKind: VaultRemoteObjectKind? = nil,
                payloadGeneration: String? = nil) {
        self.operation = operation; self.objectID = objectID
        self.objectKind = objectKind; self.payloadGeneration = payloadGeneration
        self.revision = revision; self.expectedRevision = expectedRevision
        self.chunkIndex = chunkIndex; self.totalChunks = totalChunks
        self.totalCiphertextBytes = totalCiphertextBytes
        self.offset = offset; self.length = length
        self.idempotencyKey = idempotencyKey; self.ciphertext = ciphertext
    }

    public func validated() throws -> VaultMacRequest {
        guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 256 else { throw VaultMacProtocolError.invalidRequest }
        switch operation {
        case .putChunk:
            guard let revision, revision.objectID == objectID,
                  let chunkIndex, let totalChunks, totalChunks > 0, chunkIndex < totalChunks,
                  totalChunks <= VaultMacProtocol.maximumChunks,
                  let totalCiphertextBytes, totalCiphertextBytes > 0,
                  totalCiphertextBytes <= VaultMacProtocol.maximumObjectBytes,
                  let ciphertext, !ciphertext.isEmpty,
                  ciphertext.count <= VaultMacProtocol.maximumTransferBytes,
                  UInt64(ciphertext.count) <= totalCiphertextBytes else { throw VaultMacProtocolError.invalidRequest }
            // Every Mac object is an authenticated LVF generation.  Raw
            // ciphertext uploads would let a peer publish bytes that the
            // companion cannot bind to an object kind or immutable identity.
            guard let objectKind, let payloadGeneration,
                  payloadGeneration.count == 64,
                  payloadGeneration.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw VaultMacProtocolError.invalidRequest
            }
            _ = objectKind
        case .stat:
            guard revision == nil, ciphertext == nil, offset == nil, length == nil else { throw VaultMacProtocolError.invalidRequest }
        case .readRange:
            guard revision == nil, ciphertext == nil, let offset, let length,
                  length > 0,
                  length <= UInt64(VaultMacProtocol.maximumTransferBytes),
                  offset <= UInt64.max - length else { throw VaultMacProtocolError.invalidRequest }
        case .delete:
            guard let revision, revision.objectID == objectID,
                  expectedRevision != nil, ciphertext == nil else { throw VaultMacProtocolError.invalidRequest }
        }
        return self
    }
}

public enum VaultMacResponseStatus: String, Codable, Sendable {
    case accepted, partial, conflict, notFound, invalid, failed, quotaExceeded
}

public struct VaultMacResponse: Codable, Equatable, Sendable {
    public let status: VaultMacResponseStatus
    public let objectID: VaultObjectID
    public let currentRevision: UUID?
    public let revision: VaultRevision?
    public let receivedChunks: [UInt32]
    public let totalCiphertextBytes: UInt64?
    public let ciphertext: Data?
    public let message: String?
    public let objectKind: VaultRemoteObjectKind?
    public let payloadGeneration: String?

    public init(status: VaultMacResponseStatus, objectID: VaultObjectID,
                currentRevision: UUID? = nil, revision: VaultRevision? = nil,
                receivedChunks: [UInt32] = [],
                totalCiphertextBytes: UInt64? = nil, ciphertext: Data? = nil,
                message: String? = nil, objectKind: VaultRemoteObjectKind? = nil,
                payloadGeneration: String? = nil) {
        self.status = status; self.objectID = objectID
        self.currentRevision = currentRevision ?? revision?.revision; self.revision = revision
        self.receivedChunks = receivedChunks.sorted()
        self.totalCiphertextBytes = totalCiphertextBytes
        self.ciphertext = ciphertext; self.message = message
        self.objectKind = objectKind; self.payloadGeneration = payloadGeneration
    }
}

public struct VaultMacPairingSecret: Codable, Hashable, Sendable {
    public let rawValue: Data
    public init(rawValue: Data) throws { guard rawValue.count == 32 else { throw VaultMacProtocolError.invalidSecret }; self.rawValue = rawValue }
    public init(base64Encoded value: String) throws { guard let data = Data(base64Encoded: value) else { throw VaultMacProtocolError.invalidSecret }; try self.init(rawValue: data) }
    public var base64Encoded: String { rawValue.base64EncodedString() }
}

public struct VaultMacPairingCredential: Codable, Hashable, Sendable {
    public let pairingID: UUID
    public let secret: VaultMacPairingSecret
    public let serverBinding: Data
    public let endpointBinding: String
    public let epoch: UInt64
    public let createdAt: Date
    public let revokedAt: Date?

    public init(pairingID: UUID, secret: VaultMacPairingSecret, serverBinding: Data,
                endpointBinding: String, epoch: UInt64 = 1, createdAt: Date,
                revokedAt: Date? = nil) throws {
        guard serverBinding.count == 32, epoch > 0,
              let endpoint = try? VaultMacEndpoint(binding: endpointBinding) else {
            throw VaultMacProtocolError.invalidSecret
        }
        self.pairingID = pairingID; self.secret = secret; self.serverBinding = serverBinding
        self.endpointBinding = endpoint.binding; self.epoch = epoch
        self.createdAt = createdAt; self.revokedAt = revokedAt
    }
    public var fingerprint: String { SHA256.hash(data: serverBinding).prefix(12).map { String(format: "%02x", $0) }.joined() }
    public func rotated(secret: VaultMacPairingSecret, serverBinding: Data, endpointBinding: String, now: Date) throws -> Self {
        guard epoch < UInt64.max else { throw VaultMacProtocolError.sequenceOverflow }
        return try Self(pairingID: pairingID, secret: secret, serverBinding: serverBinding,
                        endpointBinding: endpointBinding, epoch: epoch + 1, createdAt: now)
    }
    public func revoked(now: Date) throws -> Self {
        try Self(pairingID: pairingID, secret: secret, serverBinding: serverBinding,
                 endpointBinding: endpointBinding, epoch: epoch, createdAt: createdAt, revokedAt: now)
    }
    public static func derive(offer: VaultMacPairingOffer, oneTimeCode: VaultMacPairingSecret,
                              clientNonce: Data, now: Date) throws -> Self {
        guard now < offer.expiresAt, clientNonce.count == 32 else { throw VaultMacProtocolError.expired }
        var material = Data("LunaVault-Mac-credential-v2".utf8)
        material.append(offer.nonce); material.append(clientNonce)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: oneTimeCode.rawValue),
            salt: offer.serverBinding, info: material, outputByteCount: 32).data
        return try Self(pairingID: offer.pairingID,
            secret: VaultMacPairingSecret(rawValue: key), serverBinding: offer.serverBinding,
            endpointBinding: offer.endpointBinding, createdAt: now)
    }
}

/// iPhone-side pairing storage. This is a separate, non-synchronizable Keychain
/// item from the synchronizable Vault root-key ring, so the Share extension is
/// never granted or handed the Mac credential.
public struct VaultMacKeychainCredentialStore: Sendable {
    public let descriptor: VaultKeyDescriptor
    private let store: any VaultKeyStoring
    public init(accessGroup: String, service: String,
                account: String = "paired-mac",
                store: any VaultKeyStoring = VaultKeychainStore()) {
        descriptor = VaultKeyDescriptor(service: service, account: account,
            accessGroup: accessGroup, synchronizable: false, accessibility: .whenUnlocked)
        self.store = store
    }
    public func load() throws -> VaultMacPairingCredential? {
        guard let data = try store.data(for: descriptor) else { return nil }
        guard data.count <= 16 * 1024 else { throw VaultMacProtocolError.invalidSecret }
        return try JSONDecoder().decode(VaultMacPairingCredential.self, from: data)
    }
    public func save(_ credential: VaultMacPairingCredential) throws {
        guard credential.revokedAt == nil else { throw VaultMacProtocolError.revoked }
        let data = try JSONEncoder().encode(credential)
        guard data.count <= 16 * 1024 else { throw VaultMacProtocolError.invalidSecret }
        try store.setData(data, for: descriptor)
    }
    public func remove() throws { try store.removeData(for: descriptor) }
}

/// Shown by the Mac UI as a QR/code. The one-time code is delivered separately
/// and never appears in this network-visible offer.
public struct VaultMacPairingOffer: Codable, Equatable, Sendable {
    public let pairingID: UUID
    public let serverBinding: Data
    public let endpointBinding: String
    public let nonce: Data
    public let expiresAt: Date
    public init(pairingID: UUID, serverBinding: Data, endpointBinding: String,
                nonce: Data, expiresAt: Date) throws {
        guard serverBinding.count == 32, nonce.count == 32,
              let endpoint = try? VaultMacEndpoint(binding: endpointBinding) else {
            throw VaultMacProtocolError.invalidChallenge
        }
        self.pairingID = pairingID; self.serverBinding = serverBinding
        self.endpointBinding = endpoint.binding; self.nonce = nonce; self.expiresAt = expiresAt
    }
    public var fingerprint: String { SHA256.hash(data: serverBinding).prefix(12).map { String(format: "%02x", $0) }.joined() }
}

public struct VaultMacPairingEnrollment: Codable, Equatable, Sendable {
    public let pairingID: UUID
    public let clientNonce: Data
    public let proof: Data
    public init(pairingID: UUID, clientNonce: Data, proof: Data) throws {
        guard clientNonce.count == 32, proof.count == 32 else { throw VaultMacProtocolError.invalidChallenge }
        self.pairingID = pairingID; self.clientNonce = clientNonce; self.proof = proof
    }
    public static func make(offer: VaultMacPairingOffer, oneTimeCode: VaultMacPairingSecret,
                            clientNonce: Data, now: Date) throws -> Self {
        guard now < offer.expiresAt, clientNonce.count == 32 else { throw VaultMacProtocolError.expired }
        return try Self(pairingID: offer.pairingID, clientNonce: clientNonce,
                        proof: hmac(key: oneTimeCode.rawValue, data: pairingTranscript(offer: offer, clientNonce: clientNonce)))
    }
}

/// Sensitive one-use setup material normally carried in a local QR code or
/// direct device-to-device handoff. It must not be logged or sent through the
/// unauthenticated storage listener.
public struct VaultMacPairingCapsule: Codable, Equatable, Sendable {
    public let offer: VaultMacPairingOffer
    public let oneTimeCode: VaultMacPairingSecret
    public init(offer: VaultMacPairingOffer, oneTimeCode: VaultMacPairingSecret) {
        self.offer = offer; self.oneTimeCode = oneTimeCode
    }
}

public struct VaultMacPairingClientResult: Equatable, Sendable {
    public let enrollment: VaultMacPairingEnrollment
    public let credential: VaultMacPairingCredential
    public init(enrollment: VaultMacPairingEnrollment, credential: VaultMacPairingCredential) {
        self.enrollment = enrollment; self.credential = credential
    }
}

public enum VaultMacPairingClient {
    public static func prepareEnrollment(capsule: VaultMacPairingCapsule,
                                         identityConfirmer: VaultMacServerIdentityConfirming,
                                         random: VaultRandomBytesGenerating = SystemVaultRandomBytes(),
                                         now: Date = Date()) async throws -> VaultMacPairingClientResult {
        guard now < capsule.offer.expiresAt,
              let confirmation = try await identityConfirmer.confirm(
                fingerprint: capsule.offer.fingerprint,
                endpointBinding: capsule.offer.endpointBinding),
              confirmation.fingerprint == capsule.offer.fingerprint,
              confirmation.endpointBinding == capsule.offer.endpointBinding else {
            throw VaultMacProtocolError.unconfirmedServerIdentity
        }
        let clientNonce = try random.bytes(count: 32)
        let enrollment = try VaultMacPairingEnrollment.make(offer: capsule.offer,
            oneTimeCode: capsule.oneTimeCode, clientNonce: clientNonce, now: now)
        let credential = try VaultMacPairingCredential.derive(offer: capsule.offer,
            oneTimeCode: capsule.oneTimeCode, clientNonce: clientNonce, now: now)
        return VaultMacPairingClientResult(enrollment: enrollment, credential: credential)
    }
}

public protocol VaultMacServerIdentityConfirming: Sendable {
    func confirm(fingerprint: String, endpointBinding: String) async throws
        -> VaultMacServerIdentityConfirmation?
}

public struct VaultMacServerIdentityConfirmation: Equatable, Sendable {
    public let fingerprint: String
    public let endpointBinding: String
    public let confirmedAt: Date
    public init(fingerprint: String, endpointBinding: String, confirmedAt: Date = Date()) {
        self.fingerprint = fingerprint; self.endpointBinding = endpointBinding
        self.confirmedAt = confirmedAt
    }
}

public struct VaultMacSessionChallenge: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let pairingID: UUID
    public let credentialEpoch: UInt64
    public let sessionID: UUID
    public let serverNonce: Data
    public let serverBinding: Data
    public let endpointBinding: String
    public let expiresAt: Date
    public init(pairingID: UUID, credentialEpoch: UInt64, sessionID: UUID,
                serverNonce: Data, serverBinding: Data, endpointBinding: String,
                expiresAt: Date) throws {
        guard credentialEpoch > 0, serverNonce.count == 32, serverBinding.count == 32,
              !endpointBinding.isEmpty else { throw VaultMacProtocolError.invalidChallenge }
        self.protocolVersion = VaultMacProtocol.version; self.pairingID = pairingID
        self.credentialEpoch = credentialEpoch; self.sessionID = sessionID
        self.serverNonce = serverNonce; self.serverBinding = serverBinding
        self.endpointBinding = endpointBinding; self.expiresAt = expiresAt
    }
}

public struct VaultMacSessionResponse: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let clientNonce: Data
    public let proof: Data
    public init(sessionID: UUID, clientNonce: Data, proof: Data) throws {
        guard clientNonce.count == 32, proof.count == 32 else { throw VaultMacProtocolError.invalidChallenge }
        self.sessionID = sessionID; self.clientNonce = clientNonce; self.proof = proof
    }
    public static func make(challenge: VaultMacSessionChallenge, credential: VaultMacPairingCredential,
                            clientNonce: Data, now: Date) throws -> Self {
        try validate(challenge: challenge, credential: credential, now: now)
        return try Self(sessionID: challenge.sessionID, clientNonce: clientNonce,
                        proof: hmac(key: credential.secret.rawValue,
                                    data: sessionTranscript(challenge: challenge, clientNonce: clientNonce)))
    }
}

/// The server's proof of possession. A public challenge and a bare "accepted"
/// marker are not authentication: an active peer could relay or forge them.
/// This proof binds the complete session transcript and the client's proof.
public struct VaultMacSessionAcceptance: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let proof: Data
    public init(sessionID: UUID, proof: Data) throws {
        guard proof.count == 32 else { throw VaultMacProtocolError.invalidChallenge }
        self.sessionID = sessionID; self.proof = proof
    }
    public static func make(challenge: VaultMacSessionChallenge,
                            response: VaultMacSessionResponse,
                            credential: VaultMacPairingCredential,
                            now: Date) throws -> Self {
        _ = try VaultMacSessionKeys(challenge: challenge, response: response,
                                    credential: credential, now: now)
        return try Self(sessionID: challenge.sessionID,
            proof: hmac(key: credential.secret.rawValue,
                        data: serverAcceptanceTranscript(challenge: challenge, response: response)))
    }
    public func verify(challenge: VaultMacSessionChallenge,
                       response: VaultMacSessionResponse,
                       credential: VaultMacPairingCredential,
                       now: Date) throws {
        guard sessionID == challenge.sessionID else { throw VaultMacProtocolError.wrongSession }
        let expected = try Self.make(challenge: challenge, response: response,
                                     credential: credential, now: now)
        guard constantTimeEqual(proof, expected.proof) else {
            throw VaultMacProtocolError.authenticationFailed
        }
    }
}

public enum VaultMacHandshakeKind: String, Codable, Sendable { case challenge, response, accepted, rejected }
public struct VaultMacHandshakeMessage: Codable, Equatable, Sendable {
    public let kind: VaultMacHandshakeKind
    public let challenge: VaultMacSessionChallenge?
    public let response: VaultMacSessionResponse?
    public let acceptance: VaultMacSessionAcceptance?
    public init(kind: VaultMacHandshakeKind, challenge: VaultMacSessionChallenge? = nil,
                response: VaultMacSessionResponse? = nil,
                acceptance: VaultMacSessionAcceptance? = nil) {
        self.kind = kind; self.challenge = challenge; self.response = response
        self.acceptance = acceptance
    }
}

public struct VaultMacSessionKeys: Equatable, Sendable {
    public let requestKey: Data
    public let responseKey: Data
    public init(challenge: VaultMacSessionChallenge, response: VaultMacSessionResponse,
                credential: VaultMacPairingCredential, now: Date) throws {
        try validate(challenge: challenge, credential: credential, now: now)
        guard response.sessionID == challenge.sessionID else { throw VaultMacProtocolError.wrongSession }
        let transcript = sessionTranscript(challenge: challenge, clientNonce: response.clientNonce)
        guard constantTimeEqual(response.proof, hmac(key: credential.secret.rawValue, data: transcript)) else { throw VaultMacProtocolError.authenticationFailed }
        let salt = SHA256.hash(data: transcript).withUnsafeBytes { Data($0) }
        let baseKey = SymmetricKey(data: credential.secret.rawValue)
        requestKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: baseKey, salt: salt,
            info: Data("LunaVault-Mac-request-v2".utf8), outputByteCount: 32).data
        responseKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: baseKey, salt: salt,
            info: Data("LunaVault-Mac-response-v2".utf8), outputByteCount: 32).data
    }
}

public enum VaultMacFrameDirection: UInt8, Codable, Sendable { case request = 1, response = 2 }

/// Only routing data is visible. Operation, object identity, revisions, byte
/// ranges, and content are inside this directional AES-GCM envelope.
public struct VaultMacAuthenticatedFrame: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let sessionID: UUID
    public let direction: VaultMacFrameDirection
    public let sequence: UInt64
    public var ciphertext: Data
    public var tag: Data
    public init(protocolVersion: UInt16 = VaultMacProtocol.version, sessionID: UUID,
                direction: VaultMacFrameDirection, sequence: UInt64,
                ciphertext: Data, tag: Data) {
        self.protocolVersion = protocolVersion; self.sessionID = sessionID
        self.direction = direction; self.sequence = sequence
        self.ciphertext = ciphertext; self.tag = tag
    }
    public static func seal(plaintext: Data, sessionID: UUID, direction: VaultMacFrameDirection,
                            sequence: UInt64, key: Data) throws -> Self {
        guard sequence > 0, key.count == 32 else { throw VaultMacProtocolError.invalidFrame }
        guard plaintext.count <= VaultMacProtocol.maximumFrameBytes else { throw VaultMacProtocolError.frameTooLarge }
        let nonce = try AES.GCM.Nonce(data: nonceData(direction: direction, sequence: sequence))
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce,
                                   authenticating: aad(sessionID: sessionID, direction: direction, sequence: sequence))
        return Self(sessionID: sessionID, direction: direction, sequence: sequence,
                    ciphertext: Data(box.ciphertext), tag: Data(box.tag))
    }
    public func open(key: Data, expectedSessionID: UUID,
                     expectedDirection: VaultMacFrameDirection) throws -> Data {
        guard protocolVersion == VaultMacProtocol.version else { throw VaultMacProtocolError.wrongProtocolVersion }
        guard sessionID == expectedSessionID else { throw VaultMacProtocolError.wrongSession }
        guard direction == expectedDirection else { throw VaultMacProtocolError.wrongDirection }
        guard sequence > 0, key.count == 32, ciphertext.count <= VaultMacProtocol.maximumFrameBytes,
              tag.count == 16 else { throw VaultMacProtocolError.invalidFrame }
        do {
            let nonce = try AES.GCM.Nonce(data: Self.nonceData(direction: direction, sequence: sequence))
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key),
                authenticating: Self.aad(sessionID: sessionID, direction: direction, sequence: sequence))
        } catch { throw VaultMacProtocolError.authenticationFailed }
    }
    private static func nonceData(direction: VaultMacFrameDirection, sequence: UInt64) -> Data {
        var data = Data([0x4c, 0x56, 0x4d, direction.rawValue]); var value = sequence.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }; return data
    }
    private static func aad(sessionID: UUID, direction: VaultMacFrameDirection, sequence: UInt64) -> Data {
        var data = Data("LunaVault-Mac-frame-v2".utf8); data.append(sessionID.uuidData)
        data.append(direction.rawValue); var value = sequence.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }; return data
    }
}

public final class VaultMacReplayGuard: @unchecked Sendable {
    private let lock = NSLock(); private var nextExpected: UInt64 = 1
    private let key: Data; private let sessionID: UUID; private let direction: VaultMacFrameDirection
    public init(key: Data, sessionID: UUID, direction: VaultMacFrameDirection) {
        self.key = key; self.sessionID = sessionID; self.direction = direction
    }
    public func open(_ frame: VaultMacAuthenticatedFrame) throws -> Data {
        try lock.withLock {
            guard frame.sequence >= nextExpected else { throw VaultMacProtocolError.replayedFrame }
            guard frame.sequence == nextExpected else { throw VaultMacProtocolError.outOfOrderFrame }
            let plaintext = try frame.open(key: key, expectedSessionID: sessionID, expectedDirection: direction)
            guard nextExpected < UInt64.max else { throw VaultMacProtocolError.sequenceOverflow }
            nextExpected += 1; return plaintext
        }
    }
}

public final class VaultMacSendSequence: @unchecked Sendable {
    private let lock = NSLock(); private var nextSequence: UInt64 = 1
    private let key: Data; private let sessionID: UUID; private let direction: VaultMacFrameDirection
    public init(key: Data, sessionID: UUID, direction: VaultMacFrameDirection) {
        self.key = key; self.sessionID = sessionID; self.direction = direction
    }
    public func seal(_ plaintext: Data) throws -> VaultMacAuthenticatedFrame {
        try lock.withLock {
            guard nextSequence < UInt64.max else { throw VaultMacProtocolError.sequenceOverflow }
            let frame = try VaultMacAuthenticatedFrame.seal(plaintext: plaintext,
                sessionID: sessionID, direction: direction, sequence: nextSequence, key: key)
            nextSequence += 1; return frame
        }
    }
}

public protocol VaultMacFrameChannel: Sendable {
    func send(_ frame: Data) async throws
    func receive() async throws -> Data
    func close()
}
public protocol VaultMacFrameConnecting: Sendable {
    func connect(to endpoint: VaultMacEndpoint) async throws -> VaultMacFrameChannel
}

public struct VaultMacEndpoint: Codable, Equatable, Hashable, Sendable {
    public enum Reachability: String, Codable, Sendable { case tailscale, lanBonjour }
    public let host: String; public let port: UInt16; public let reachability: Reachability
    public init(binding: String) throws {
        guard let separator = binding.firstIndex(of: ":"),
              let reachability = Reachability(rawValue: String(binding[..<separator])) else {
            throw VaultMacProtocolError.invalidEndpoint
        }
        let hostAndPort = binding[binding.index(after: separator)...]
        guard let portSeparator = hostAndPort.lastIndex(of: ":"),
              portSeparator > hostAndPort.startIndex,
              let port = UInt16(hostAndPort[hostAndPort.index(after: portSeparator)...]) else {
            throw VaultMacProtocolError.invalidEndpoint
        }
        try self.init(host: String(hostAndPort[..<portSeparator]), port: port,
                      reachability: reachability)
    }
    public init(host: String, port: UInt16, reachability: Reachability) throws {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard port > 0, Self.isValid(normalized, reachability: reachability) else { throw VaultMacProtocolError.invalidEndpoint }
        self.host = normalized; self.port = port; self.reachability = reachability
    }
    public var binding: String { "\(reachability.rawValue):\(host):\(port)" }
    private static func isValid(_ host: String, reachability: Reachability) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, !host.contains("://"),
              !host.contains("/"), !host.contains("@") else { return false }
        switch reachability {
        case .tailscale:
            if host.hasSuffix(".ts.net") { return validHostname(host) }
            if let ip = ipv4Bytes(host) { return ip[0] == 100 && (64...127).contains(ip[1]) }
            return tailscaleIPv6(host)
        case .lanBonjour: return host.hasSuffix(".local") && validHostname(host)
        }
    }
    private static func validHostname(_ value: String) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" &&
            $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
    private static func ipv4Bytes(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }; let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }
    private static func tailscaleIPv6(_ value: String) -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        var address = in6_addr()
        let result = value.withCString { inet_pton(AF_INET6, $0, &address) }
        guard result == 1 else { return false }
        return withUnsafeBytes(of: &address) { bytes in
            bytes.count >= 6 && bytes[0] == 0xfd && bytes[1] == 0x7a &&
                bytes[2] == 0x11 && bytes[3] == 0x5c &&
                bytes[4] == 0xa1 && bytes[5] == 0xe0
        }
        #else
        return false
        #endif
    }
}

public struct VaultMacDiscoveryRecord: Codable, Equatable, Sendable {
    public let displayName: String; public let endpoint: VaultMacEndpoint; public let serverBinding: Data
    public init(displayName: String, endpoint: VaultMacEndpoint, serverBinding: Data) throws {
        guard !displayName.isEmpty, displayName.utf8.count <= 128,
              serverBinding.count == 32 else { throw VaultMacProtocolError.invalidEndpoint }
        self.displayName = displayName; self.endpoint = endpoint; self.serverBinding = serverBinding
    }
}
public protocol VaultMacDiscoveryBrowsing: Sendable {
    func records() -> AsyncThrowingStream<VaultMacDiscoveryRecord, Error>
}

public struct VaultMacChunkPlan: Equatable, Sendable {
    public let chunkSize: Int; public let totalChunks: UInt32; public let byteCount: UInt64
    public init(byteCount: UInt64, chunkSize: Int = VaultMacProtocol.maximumTransferBytes) throws {
        guard byteCount > 0, byteCount <= VaultMacProtocol.maximumObjectBytes,
              chunkSize > 0, chunkSize <= VaultMacProtocol.maximumTransferBytes else { throw VaultMacProtocolError.objectTooLarge }
        let divisor = UInt64(chunkSize), adjusted = try checkedAdd(byteCount, divisor - 1)
        let count = adjusted / divisor
        guard count > 0, count <= UInt64(UInt32.max) else { throw VaultMacProtocolError.objectTooLarge }
        self.chunkSize = chunkSize; self.totalChunks = UInt32(count); self.byteCount = byteCount
    }
    public func range(for index: UInt32) throws -> Range<Int> {
        guard index < totalChunks else { throw VaultMacProtocolError.invalidRequest }
        let lower = try checkedMultiply(UInt64(index), UInt64(chunkSize))
        let upper = min(byteCount, try checkedAdd(lower, UInt64(chunkSize)))
        guard upper <= UInt64(Int.max) else { throw VaultMacProtocolError.objectTooLarge }
        return Int(lower)..<Int(upper)
    }
}

public enum VaultMacRequestFactory {
    public static func idempotencyKey(objectID: VaultObjectID, revision: UUID, chunkIndex: UInt32) -> String {
        var data = Data("LunaVault-Mac-put-v2".utf8); data.append(objectID.rawValue.uuidData)
        data.append(revision.uuidData); var value = chunkIndex.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private func validate(challenge: VaultMacSessionChallenge,
                      credential: VaultMacPairingCredential, now: Date) throws {
    guard credential.revokedAt == nil else { throw VaultMacProtocolError.revoked }
    guard challenge.protocolVersion == VaultMacProtocol.version else { throw VaultMacProtocolError.wrongProtocolVersion }
    guard challenge.pairingID == credential.pairingID,
          challenge.credentialEpoch == credential.epoch,
          challenge.serverBinding == credential.serverBinding,
          challenge.endpointBinding == credential.endpointBinding else { throw VaultMacProtocolError.authenticationFailed }
    guard now < challenge.expiresAt else { throw VaultMacProtocolError.expired }
}
private func pairingTranscript(offer: VaultMacPairingOffer, clientNonce: Data) -> Data {
    var data = Data("LunaVault-Mac-pair-v2".utf8); data.append(offer.pairingID.uuidData)
    data.append(offer.serverBinding); data.append(Data(offer.endpointBinding.utf8))
    data.append(offer.nonce); data.append(clientNonce)
    var expiry = offer.expiresAt.timeIntervalSince1970.bitPattern.bigEndian
    withUnsafeBytes(of: &expiry) { data.append(contentsOf: $0) }; return data
}
private func sessionTranscript(challenge: VaultMacSessionChallenge, clientNonce: Data) -> Data {
    var data = Data("LunaVault-Mac-session-v2".utf8); data.append(challenge.pairingID.uuidData)
    data.append(challenge.sessionID.uuidData); data.append(challenge.serverNonce); data.append(clientNonce)
    data.append(challenge.serverBinding); data.append(Data(challenge.endpointBinding.utf8))
    var epoch = challenge.credentialEpoch.bigEndian
    withUnsafeBytes(of: &epoch) { data.append(contentsOf: $0) }; return data
}
private func serverAcceptanceTranscript(challenge: VaultMacSessionChallenge,
                                        response: VaultMacSessionResponse) -> Data {
    var data = Data("LunaVault-Mac-server-accept-v2".utf8)
    data.append(sessionTranscript(challenge: challenge, clientNonce: response.clientNonce))
    data.append(response.proof)
    return data
}
private func hmac(key: Data, data: Data) -> Data {
    HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)).withUnsafeBytes { Data($0) }
}
private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw VaultMacProtocolError.objectTooLarge }; return value
}
private func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw VaultMacProtocolError.objectTooLarge }; return value
}
private extension UUID {
    var uuidData: Data { var value = uuid; return withUnsafeBytes(of: &value) { Data($0) } }
}
private extension SymmetricKey { var data: Data { withUnsafeBytes { Data($0) } } }
private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
