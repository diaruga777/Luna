import CryptoKit
import Foundation
import LunaAppConfig
import LunaVaultModels
#if canImport(Security)
import Security
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum LunaVaultCryptoModule { public static let identifier = "LunaVaultCrypto" }

public struct VaultCryptoConfiguration: Equatable, Sendable {
    public let keychainAccessGroup: String
    public let vaultID: String
    public let keychainService: String
    public init(keychainAccessGroup: String, vaultID: String = "default", keychainService: String? = nil, appGroupID: String = AppConfig.provisionedAppGroupID, hostBundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.keychainAccessGroup = keychainAccessGroup
        self.vaultID = vaultID
        self.keychainService = keychainService ?? Self.defaultKeychainService(appGroupID: appGroupID, hostBundleIdentifier: hostBundleIdentifier)
    }
    /// Stable across the Vault host and any future explicitly-authorized host.
    /// App-extension bundle identifiers are intentionally not part of this identity.
    public static func defaultKeychainService(appGroupID: String, hostBundleIdentifier: String?) -> String {
        _ = hostBundleIdentifier // Deliberately excluded: target suffixes are not Keychain identity.
        let namespace = appGroupID.hasPrefix("group.") ? String(appGroupID.dropFirst("group.".count)) : appGroupID
        return "\(namespace).vault.keys"
    }
}

public enum VaultKeyAccessibility: String, Codable, Sendable { case afterFirstUnlock, whenUnlocked }
public struct VaultKeyDescriptor: Codable, Hashable, Sendable {
    public let service: String
    public let account: String
    public let accessGroup: String
    public let synchronizable: Bool
    public let accessibility: VaultKeyAccessibility
    public init(service: String, account: String, accessGroup: String, synchronizable: Bool, accessibility: VaultKeyAccessibility) {
        self.service = service; self.account = account; self.accessGroup = accessGroup
        self.synchronizable = synchronizable; self.accessibility = accessibility
    }
}

public protocol VaultKeyStoring: Sendable {
    func data(for descriptor: VaultKeyDescriptor) throws -> Data?
    func setData(_ data: Data, for descriptor: VaultKeyDescriptor) throws
    func removeData(for descriptor: VaultKeyDescriptor) throws
}
public protocol VaultAtomicKeyStoring: VaultKeyStoring {
    func createDataIfAbsent(_ data: Data, for descriptor: VaultKeyDescriptor) throws -> Bool
}
public struct SystemVaultRandomBytes: VaultRandomBytesGenerating {
    public init() {}
    public func bytes(count: Int) throws -> Data {
        guard count >= 0 else { throw VaultCryptoError.invalidLength }
        var output = Data(); output.reserveCapacity(count)
        while output.count < count {
            let key = SymmetricKey(size: .bits256)
            key.withUnsafeBytes { output.append(contentsOf: $0.prefix(count - output.count)) }
        }
        return output
    }
}

public enum VaultCryptoError: Error, Equatable, Sendable {
    case invalidLength, malformedEnvelope, authenticationFailed, wrongVault, wrongObject
    case wrongRevision, wrongRole, wrongRootVersion, missingRootKey, corruptRootKey
    case keyUnavailable, invalidRange, unsupportedVersion, inputTooLarge, tooManyChunks
    case keychain(OSStatus)
}

public struct VaultKeychainQuery: Equatable, Sendable {
    public enum Operation: Sendable { case read, add, update, delete }
    public let descriptor: VaultKeyDescriptor
    public let operation: Operation
    public init(descriptor: VaultKeyDescriptor, operation: Operation) { self.descriptor = descriptor; self.operation = operation }
}

public struct VaultKeychainStore: VaultAtomicKeyStoring {
    public init() {}
    public func query(for descriptor: VaultKeyDescriptor, operation: VaultKeychainQuery.Operation) -> VaultKeychainQuery {
        VaultKeychainQuery(descriptor: descriptor, operation: operation)
    }
    public func data(for descriptor: VaultKeyDescriptor) throws -> Data? {
#if canImport(Security)
        var query = baseQuery(descriptor)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultCryptoError.keychain(status) }
        return value as? Data
#else
        _ = descriptor; return nil
#endif
    }
    public func createDataIfAbsent(_ data: Data, for descriptor: VaultKeyDescriptor) throws -> Bool {
#if canImport(Security)
        var query = baseQuery(descriptor); query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibility(descriptor.accessibility)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw VaultCryptoError.keychain(status) }
        return true
#else
        _ = data; _ = descriptor; throw VaultCryptoError.keychain(-1)
#endif
    }
    public func setData(_ data: Data, for descriptor: VaultKeyDescriptor) throws {
#if canImport(Security)
        let query = baseQuery(descriptor)
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessibility(descriptor.accessibility)]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { _ = try createDataIfAbsent(data, for: descriptor); return }
        guard status == errSecSuccess else { throw VaultCryptoError.keychain(status) }
#else
        _ = data; _ = descriptor; throw VaultCryptoError.keychain(-1)
#endif
    }
    public func removeData(for descriptor: VaultKeyDescriptor) throws {
#if canImport(Security)
        let status = SecItemDelete(baseQuery(descriptor) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultCryptoError.keychain(status) }
#else
        _ = descriptor
#endif
    }
#if canImport(Security)
    private func baseQuery(_ descriptor: VaultKeyDescriptor) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: descriptor.service,
         kSecAttrAccount as String: descriptor.account,
         kSecAttrAccessGroup as String: descriptor.accessGroup,
         kSecAttrSynchronizable as String: descriptor.synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!]
    }
    private func accessibility(_ value: VaultKeyAccessibility) -> CFString {
        value == .whenUnlocked ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleAfterFirstUnlock
    }
#endif
}

public struct VaultRootKey: Codable, Hashable, Sendable {
    public let version: UInt32
    public let key: Data
    public let fingerprint: String
    public init(version: UInt32, key: Data) throws {
        guard version > 0, key.count == 32 else { throw VaultCryptoError.invalidLength }
        self.version = version; self.key = key; self.fingerprint = Self.fingerprint(of: key)
    }
    static func fingerprint(of key: Data) -> String { SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined() }
}

public final class VaultRootKeyManager: @unchecked Sendable {
    private static let lock = NSLock()
    public let descriptor: VaultKeyDescriptor
    private let store: VaultKeyStoring
    private let random: VaultRandomBytesGenerating
    private let lifecycleLockURL: URL?
    public init(configuration: VaultCryptoConfiguration, store: VaultKeyStoring = VaultKeychainStore(), random: VaultRandomBytesGenerating = SystemVaultRandomBytes(), lifecycleLockURL: URL? = AppConfig.sharedContainerURL()?.appendingPathComponent(".vault-key-lifecycle.lock")) {
        self.store = store; self.random = random
        self.lifecycleLockURL = lifecycleLockURL
        descriptor = VaultKeyDescriptor(service: configuration.keychainService, account: configuration.vaultID,
            accessGroup: configuration.keychainAccessGroup, synchronizable: true, accessibility: .whenUnlocked)
    }
    /// Setup-only. Launch and recovery paths must call `loadRequired`.
    public func createFirstRun() throws -> VaultRootKey { try synchronized {
        if let existing = try store.data(for: descriptor) { return try decodeRing(existing).last! }
        let root = try VaultRootKey(version: 1, key: random.bytes(count: 32))
        let bytes = try JSONEncoder().encode([root])
        if let atomic = store as? VaultAtomicKeyStoring, try !atomic.createDataIfAbsent(bytes, for: descriptor) {
            guard let winner = try store.data(for: descriptor) else { throw VaultCryptoError.keyUnavailable }
            return try decodeRing(winner).last!
        }
        if !(store is VaultAtomicKeyStoring) { try store.setData(bytes, for: descriptor) }
        return root
    }}
    @available(*, deprecated, message: "Setup-only; use createFirstRun. Never call from ambient launch.")
    public func loadOrCreate() throws -> VaultRootKey { try createFirstRun() }
    public func loadRequired() throws -> VaultRootKey { guard let data = try store.data(for: descriptor) else { throw VaultCryptoError.keyUnavailable }; return try decodeRing(data).last! }
    public func key(version: UInt32) throws -> VaultRootKey { guard let data = try store.data(for: descriptor), let key = try decodeRing(data).first(where: { $0.version == version }) else { throw VaultCryptoError.keyUnavailable }; return key }
    public func rotate() throws -> VaultRootKey { try synchronized {
        guard let before = try store.data(for: descriptor) else { throw VaultCryptoError.keyUnavailable }
        var ring = try decodeRing(before); guard ring.count < 64 else { throw VaultCryptoError.corruptRootKey }
        guard ring.last!.version < UInt32.max else { throw VaultCryptoError.corruptRootKey }
        let next = try VaultRootKey(version: ring.last!.version + 1, key: random.bytes(count: 32)); ring.append(next)
        try store.setData(try JSONEncoder().encode(ring), for: descriptor)
        guard let after = try store.data(for: descriptor), try decodeRing(after).contains(next) else { throw VaultCryptoError.keyUnavailable }
        return next
    }}
    /// Deletes only this Vault's root-ring item. Callers must separately confirm destructive reset.
    public func resetConfirmed() throws { try synchronized { try store.removeData(for: descriptor) } }
    private func synchronized<T>(_ body: () throws -> T) throws -> T {
        try Self.lock.withLock {
            guard let lifecycleLockURL else { return try body() }
            let descriptor = open(lifecycleLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw VaultCryptoError.keyUnavailable }
            defer { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw VaultCryptoError.keyUnavailable }
            return try body()
        }
    }
    private func decodeRing(_ data: Data) throws -> [VaultRootKey] {
        guard data.count <= 16_384, let ring = try? JSONDecoder().decode([VaultRootKey].self, from: data), !ring.isEmpty, ring.count <= 64 else { throw VaultCryptoError.corruptRootKey }
        var previous: UInt32 = 0
        for key in ring {
            guard key.version > previous, key.key.count == 32, key.fingerprint == VaultRootKey.fingerprint(of: key.key) else { throw VaultCryptoError.corruptRootKey }
            previous = key.version
        }
        return ring
    }
}

public enum VaultEnvelopeRole: UInt8, Codable, Sendable { case content = 1, metadata = 2, index = 3, dek = 4 }
public struct VaultChunkEnvelope: Sendable, Equatable {
    public static let version: UInt8 = 1
    public static let headerSize = 2 + 4 + 16 + 16 + 4 + 8 + 12
    public let role: VaultEnvelopeRole; public let rootVersion: UInt32; public let objectID: VaultObjectID
    public let revision: UUID; public let chunkIndex: UInt32; public let plaintextLength: UInt64
    public let nonce: Data; public let ciphertext: Data
    public init(role: VaultEnvelopeRole, rootVersion: UInt32, objectID: VaultObjectID, revision: UUID, chunkIndex: UInt32, plaintextLength: UInt64, nonce: Data, ciphertext: Data) {
        self.role=role; self.rootVersion=rootVersion; self.objectID=objectID; self.revision=revision
        self.chunkIndex=chunkIndex; self.plaintextLength=plaintextLength; self.nonce=nonce; self.ciphertext=ciphertext
    }
    public func encoded() throws -> Data {
        guard rootVersion > 0, plaintextLength <= 100_000_000_000, nonce.count == 12,
              ciphertext.count >= 16, ciphertext.count <= 8_388_608 + 16 else { throw VaultCryptoError.malformedEnvelope }
        var data = Data([Self.version, role.rawValue]); data.append(contentsOf: be(rootVersion)); data.append(objectID.rawValue.uuidData)
        data.append(revision.uuidData); data.append(contentsOf: be(chunkIndex)); data.append(contentsOf: be(plaintextLength)); data.append(nonce); data.append(ciphertext); return data
    }
    public static func decode(_ data: Data, maximumBytes: Int = 1_048_576 + headerSize + 16) throws -> VaultChunkEnvelope {
        guard maximumBytes >= headerSize + 16, data.count >= headerSize + 16, data.count <= maximumBytes,
              data[0] == version, let role = VaultEnvelopeRole(rawValue: data[1]) else { throw VaultCryptoError.malformedEnvelope }
        var i=2; let root=try read32(data,&i); guard root > 0 else { throw VaultCryptoError.malformedEnvelope }
        let object=try readUUID(data,&i), revision=try readUUID(data,&i), index=try read32(data,&i), length=try read64(data,&i)
        guard length <= 100_000_000_000 else { throw VaultCryptoError.inputTooLarge }
        let nonce=Data(data[i..<i+12]); i += 12
        return VaultChunkEnvelope(role: role, rootVersion: root, objectID: VaultObjectID(rawValue: object), revision: revision, chunkIndex: index, plaintextLength: length, nonce: nonce, ciphertext: Data(data[i...]))
    }
}

public struct VaultSealedObject: Sendable, Equatable {
    public let objectID: VaultObjectID; public let revision: UUID; public let rootVersion: UInt32
    public let wrappedDEK: Data; public let chunks: [Data]
    public init(objectID: VaultObjectID, revision: UUID, rootVersion: UInt32, wrappedDEK: Data, chunks: [Data]) { self.objectID=objectID; self.revision=revision; self.rootVersion=rootVersion; self.wrappedDEK=wrappedDEK; self.chunks=chunks }
}

public struct VaultChunkedCryptor: Sendable {
    public static let maximumObjectBytes: UInt64 = 100_000_000_000
    public let chunkSize: Int; public let vaultID: String
    let random: VaultRandomBytesGenerating
    public init(chunkSize: Int = 1_048_576, vaultID: String = "default", random: VaultRandomBytesGenerating = SystemVaultRandomBytes()) {
        self.chunkSize = min(max(chunkSize, 1), 8_388_608); self.vaultID = vaultID; self.random = random
    }
    public func seal(_ plaintext: Data, objectID: VaultObjectID, revision: UUID, root: VaultRootKey, role: VaultEnvelopeRole = .content) throws -> [Data] {
        guard role != .dek, UInt64(plaintext.count) <= Self.maximumObjectBytes else { throw VaultCryptoError.inputTooLarge }
        let dek=try random.bytes(count:32); guard dek.count == 32 else { throw VaultCryptoError.invalidLength }
        var nonces=Set<Data>(); let wrapNonce=try uniqueNonce(&nonces)
        var result=[try wrap(dek,root,objectID,revision,wrapNonce)]; let key=SymmetricKey(data:dek)
        let count=max(1,(plaintext.count + chunkSize - 1) / chunkSize); guard count <= Int(UInt32.max) else { throw VaultCryptoError.tooManyChunks }
        for number in 0..<count {
            if Task.isCancelled { throw VaultCryptoError.invalidLength }
            let start=min(plaintext.count,number*chunkSize), end=min(plaintext.count,start+chunkSize); let nonceData=try uniqueNonce(&nonces)
            let aad=associatedData(role,root.version,objectID,revision,UInt32(number),UInt64(plaintext.count))
            let box=try AES.GCM.seal(Data(plaintext[start..<end]),using:key,nonce:try AES.GCM.Nonce(data:nonceData),authenticating:aad)
            result.append(try VaultChunkEnvelope(role:role,rootVersion:root.version,objectID:objectID,revision:revision,chunkIndex:UInt32(number),plaintextLength:UInt64(plaintext.count),nonce:nonceData,ciphertext:box.ciphertext+box.tag).encoded())
        }
        return result
    }
    public func open(_ frames:[Data], objectID:VaultObjectID, revision:UUID, role:VaultEnvelopeRole = .content, rootKey:(UInt32)throws->VaultRootKey)throws->Data {
        let parsed=try validate(frames,objectID,revision,role); guard parsed.length <= UInt64(Int.max) else { throw VaultCryptoError.inputTooLarge }
        return try decrypt(frames,parsed,0..<Int(parsed.length),rootKey)
    }
    public func openRange(_ frames:[Data], range:Range<Int>, objectID:VaultObjectID, revision:UUID, role:VaultEnvelopeRole = .content, rootKey:(UInt32)throws->VaultRootKey)throws->Data {
        let parsed=try validate(frames,objectID,revision,role); guard parsed.length <= UInt64(Int.max), range.lowerBound >= 0, range.upperBound >= range.lowerBound, UInt64(range.upperBound) <= parsed.length else { throw VaultCryptoError.invalidRange }
        if range.isEmpty { _ = try open(frames, objectID: objectID, revision: revision, role: role, rootKey: rootKey); return Data() }
        return try decrypt(frames,parsed,range,rootKey)
    }

    /// Authenticates and opens one encrypted frame without materialising the
    /// surrounding object.  The caller must have already structurally
    /// validated the frame-file header and supplies the wrapped DEK frame for
    /// every call.  This is the bounded primitive used by 100-GB transfers.
    public func openFrame(_ wrappedDEK: Data, frame: Data, objectID: VaultObjectID,
                          revision: UUID, role: VaultEnvelopeRole,
                          chunkIndex: UInt32, plaintextLength: UInt64,
                          rootKey: (UInt32) throws -> VaultRootKey) throws -> Data {
        let envelope = try VaultChunkEnvelope.decode(
            frame, maximumBytes: chunkSize + VaultChunkEnvelope.headerSize + 16)
        guard envelope.objectID == objectID, envelope.revision == revision,
              envelope.role == role, envelope.chunkIndex == chunkIndex,
              envelope.plaintextLength == plaintextLength else {
            throw VaultCryptoError.malformedEnvelope
        }
        let root = try rootKey(envelope.rootVersion)
        guard root.version == envelope.rootVersion else { throw VaultCryptoError.wrongRootVersion }
        let dek = try unwrap(wrappedDEK, root, objectID, revision)
        let aad = associatedData(role, envelope.rootVersion, objectID, revision,
                                 chunkIndex, plaintextLength)
        do {
            return try AES.GCM.open(try sealedBox(envelope),
                                    using: SymmetricKey(data: dek), authenticating: aad)
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }
    public func planRange(_ range:Range<Int>,plaintextLength:Int)throws->Range<Int>{guard plaintextLength>=0,range.lowerBound>=0,range.upperBound<=plaintextLength,range.lowerBound<=range.upperBound else{throw VaultCryptoError.invalidRange};if range.isEmpty{return 0..<0};return (range.lowerBound/chunkSize)..<((range.upperBound-1)/chunkSize+1)}
    private struct Parsed { let envelopes:[VaultChunkEnvelope]; let length:UInt64; let rootVersion:UInt32 }
    private func validate(_ frames:[Data],_ object:VaultObjectID,_ revision:UUID,_ role:VaultEnvelopeRole)throws->Parsed {
        guard frames.count >= 2, frames.count <= Int(UInt32.max) else { throw VaultCryptoError.tooManyChunks }
        var envelopes=[VaultChunkEnvelope](); envelopes.reserveCapacity(frames.count-1)
        for number in 0..<(frames.count-1) {
            let envelope=try VaultChunkEnvelope.decode(frames[number+1],maximumBytes:chunkSize+VaultChunkEnvelope.headerSize+16)
            guard envelope.objectID == object else { throw VaultCryptoError.wrongObject }; guard envelope.revision == revision else { throw VaultCryptoError.wrongRevision }
            guard envelope.role == role else { throw VaultCryptoError.wrongRole }; guard envelope.chunkIndex == UInt32(number) else { throw VaultCryptoError.malformedEnvelope }
            guard envelope.plaintextLength <= Self.maximumObjectBytes else { throw VaultCryptoError.inputTooLarge }
            if let first=envelopes.first { guard first.rootVersion == envelope.rootVersion else { throw VaultCryptoError.wrongRootVersion }; guard first.plaintextLength == envelope.plaintextLength else { throw VaultCryptoError.invalidLength } }
            envelopes.append(envelope)
        }
        let length=envelopes[0].plaintextLength; let expected=max(1,(Int(length)+chunkSize-1)/chunkSize); guard expected == envelopes.count else { throw VaultCryptoError.invalidLength }
        for (i,e) in envelopes.enumerated() { let expectedPlain = length == 0 ? 0 : min(chunkSize,Int(length)-i*chunkSize); guard e.ciphertext.count == expectedPlain+16 else { throw VaultCryptoError.invalidLength } }
        return Parsed(envelopes:envelopes,length:length,rootVersion:envelopes[0].rootVersion)
    }
    private func decrypt(_ frames:[Data],_ parsed:Parsed,_ range:Range<Int>,_ rootKey:(UInt32)throws->VaultRootKey)throws->Data {
        let root=try rootKey(parsed.rootVersion); guard root.version == parsed.rootVersion else { throw VaultCryptoError.wrongRootVersion }
        let dek=try unwrap(frames[0],root,parsed.envelopes[0].objectID,parsed.envelopes[0].revision); let key=SymmetricKey(data:dek)
        let chunks=try planRange(range,plaintextLength:Int(parsed.length)); var output=Data(); output.reserveCapacity(range.count)
        for number in chunks {
            if Task.isCancelled { throw VaultCryptoError.invalidLength }
            let e=parsed.envelopes[number]; let aad=associatedData(e.role,e.rootVersion,e.objectID,e.revision,e.chunkIndex,e.plaintextLength); let box=try sealedBox(e)
            let plain:Data; do { plain=try AES.GCM.open(box,using:key,authenticating:aad) } catch { throw VaultCryptoError.authenticationFailed }
            let chunkStart=number*chunkSize, lower=max(range.lowerBound,chunkStart)-chunkStart, upper=min(range.upperBound,chunkStart+plain.count)-chunkStart
            if lower < upper { output.append(plain[lower..<upper]) }
        }
        guard output.count == range.count else { throw VaultCryptoError.invalidLength }; return output
    }
    private func uniqueNonce(_ seen: inout Set<Data>) throws -> Data { let nonce=try random.bytes(count:12);guard nonce.count==12 else{throw VaultCryptoError.invalidLength};guard seen.insert(nonce).inserted else{throw VaultCryptoError.authenticationFailed};return nonce }
    func wrap(_ dek:Data,_ root:VaultRootKey,_ object:VaultObjectID,_ revision:UUID,_ nonce:Data)throws->Data {let box=try AES.GCM.seal(dek,using:SymmetricKey(data:root.key),nonce:try AES.GCM.Nonce(data:nonce),authenticating:associatedData(.dek,root.version,object,revision,0,32));return Data([1])+Data(be(root.version))+vaultFingerprint()+object.rawValue.uuidData+revision.uuidData+nonce+box.ciphertext+box.tag }
    private func unwrap(_ frame:Data,_ root:VaultRootKey,_ object:VaultObjectID,_ revision:UUID)throws->Data { guard frame.count==113,frame[0]==1 else{throw VaultCryptoError.malformedEnvelope};var i=1;let version=try read32(frame,&i);guard version==root.version else{throw VaultCryptoError.wrongRootVersion};guard Data(frame[i..<i+16])==vaultFingerprint()else{throw VaultCryptoError.wrongVault};i+=16;guard try readUUID(frame,&i)==object.rawValue else{throw VaultCryptoError.wrongObject};guard try readUUID(frame,&i)==revision else{throw VaultCryptoError.wrongRevision};let nonce=try AES.GCM.Nonce(data:frame[i..<i+12]);i+=12;let body=frame[i...];let box=try AES.GCM.SealedBox(nonce:nonce,ciphertext:body.dropLast(16),tag:body.suffix(16));do{let key=try AES.GCM.open(box,using:SymmetricKey(data:root.key),authenticating:associatedData(.dek,root.version,object,revision,0,32));guard key.count==32 else{throw VaultCryptoError.invalidLength};return key}catch let e as VaultCryptoError{throw e}catch{throw VaultCryptoError.authenticationFailed} }
    private func vaultFingerprint()->Data{Data(SHA256.hash(data:Data(vaultID.utf8)).prefix(16))}
    private func sealedBox(_ e:VaultChunkEnvelope)throws->AES.GCM.SealedBox{guard e.ciphertext.count>=16 else{throw VaultCryptoError.malformedEnvelope};return try AES.GCM.SealedBox(nonce:try AES.GCM.Nonce(data:e.nonce),ciphertext:e.ciphertext.dropLast(16),tag:e.ciphertext.suffix(16))}
    func associatedData(_ role:VaultEnvelopeRole,_ version:UInt32,_ object:VaultObjectID,_ revision:UUID,_ index:UInt32,_ length:UInt64)->Data{var d=Data("LunaVault-v1".utf8);let vault=Data(vaultID.utf8);d.append(contentsOf:be(UInt32(vault.count)));d.append(vault);d.append(role.rawValue);d.append(contentsOf:be(version));d.append(object.rawValue.uuidData);d.append(revision.uuidData);d.append(contentsOf:be(index));d.append(contentsOf:be(length));return d}
}

public extension UUID { var uuidData:Data{var value=uuid;return Data(bytes:&value,count:16)} }
private func be<T:FixedWidthInteger>(_ value:T)->[UInt8]{withUnsafeBytes(of:value.bigEndian){Array($0)}}
private func read32(_ data:Data,_ index:inout Int)throws->UInt32{guard index+4<=data.count else{throw VaultCryptoError.malformedEnvelope};let value=data[index..<index+4].reduce(UInt32(0)){($0<<8)|UInt32($1)};index+=4;return value}
private func read64(_ data:Data,_ index:inout Int)throws->UInt64{guard index+8<=data.count else{throw VaultCryptoError.malformedEnvelope};let value=data[index..<index+8].reduce(UInt64(0)){($0<<8)|UInt64($1)};index+=8;return value}
private func readUUID(_ data:Data,_ index:inout Int)throws->UUID{guard index+16<=data.count else{throw VaultCryptoError.malformedEnvelope};let a=Array(data[index..<index+16]);index+=16;return UUID(uuid:(a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7],a[8],a[9],a[10],a[11],a[12],a[13],a[14],a[15]))}
