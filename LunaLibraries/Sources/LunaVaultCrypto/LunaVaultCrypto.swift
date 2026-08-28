import Foundation
import CryptoKit
import LunaAppConfig
import LunaVaultModels
#if canImport(Security)
import Security
#endif

public enum LunaVaultCryptoModule { public static let identifier = "LunaVaultCrypto" }
public struct VaultCryptoConfiguration: Equatable, Sendable { public let keychainAccessGroup: String; public let vaultID: String; public init(keychainAccessGroup: String, vaultID: String = "default") { self.keychainAccessGroup=keychainAccessGroup; self.vaultID=vaultID } }
public enum VaultKeyAccessibility: String, Codable, Sendable { case afterFirstUnlock; case whenUnlocked }
public struct VaultKeyDescriptor: Codable, Hashable, Sendable { public let service:String; public let account:String; public let accessGroup:String; public let synchronizable:Bool; public let accessibility:VaultKeyAccessibility; public init(service:String,account:String,accessGroup:String,synchronizable:Bool,accessibility:VaultKeyAccessibility){self.service=service;self.account=account;self.accessGroup=accessGroup;self.synchronizable=synchronizable;self.accessibility=accessibility} }
public protocol VaultKeyStoring: Sendable { func data(for descriptor:VaultKeyDescriptor)throws->Data?; func setData(_ data:Data,for descriptor:VaultKeyDescriptor)throws; func removeData(for descriptor:VaultKeyDescriptor)throws }
public protocol VaultRandomBytesGenerating: Sendable { func bytes(count:Int)throws->Data }
public struct SystemVaultRandomBytes: VaultRandomBytesGenerating { public init(){}; public func bytes(count:Int)throws->Data { guard count>=0 else{throw VaultCryptoError.invalidLength}; return Data((0..<count).map{_ in UInt8.random(in:0...255)}) } }
public enum VaultCryptoError: Error, Equatable, Sendable { case invalidLength; case malformedEnvelope; case authenticationFailed; case wrongObject; case wrongRevision; case missingRootKey; case corruptRootKey; case keychain(OSStatus); case invalidRange; case unsupportedVersion }
public struct VaultKeychainStore: VaultKeyStoring {
 public init() {}
 public func data(for d: VaultKeyDescriptor) throws -> Data? {
#if canImport(Security)
  var q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:d.service, kSecAttrAccount as String:d.account, kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
  apply(d, &q); var r: CFTypeRef?; let s = SecItemCopyMatching(q as CFDictionary, &r)
  if s == errSecItemNotFound { return nil }; guard s == errSecSuccess else { throw VaultCryptoError.keychain(s) }; return r as? Data
#else
  _ = d; return nil
#endif
 }
 public func setData(_ data: Data, for d: VaultKeyDescriptor) throws {
#if canImport(Security)
  var q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:d.service, kSecAttrAccount as String:d.account]; apply(d, &q)
  let u: [String: Any] = [kSecValueData as String:data, kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlocked]
  let s = SecItemUpdate(q as CFDictionary, u as CFDictionary)
  if s == errSecItemNotFound { var a=q; a[kSecValueData as String]=data; a[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlocked; let x=SecItemAdd(a as CFDictionary,nil); guard x == errSecSuccess else { throw VaultCryptoError.keychain(x) } } else { guard s == errSecSuccess else { throw VaultCryptoError.keychain(s) } }
#else
  _ = data; _ = d; throw VaultCryptoError.keychain(-1)
#endif
 }
 public func removeData(for d: VaultKeyDescriptor) throws {
#if canImport(Security)
  var q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:d.service, kSecAttrAccount as String:d.account]; apply(d, &q); let s=SecItemDelete(q as CFDictionary); guard s == errSecSuccess || s == errSecItemNotFound else { throw VaultCryptoError.keychain(s) }
#else
  _ = d
#endif
 }
 #if canImport(Security)
 private func apply(_ d:VaultKeyDescriptor,_ q:inout [String:Any]){q[kSecAttrAccessGroup as String]=d.accessGroup;q[kSecAttrSynchronizable as String]=d.synchronizable ? kCFBooleanTrue:kCFBooleanFalse}
 #endif
}
public struct VaultRootKey: Codable, Hashable, Sendable { public let version:UInt32; public let key:Data; public let fingerprint:String; public init(version:UInt32,key:Data)throws{guard key.count==32 else{throw VaultCryptoError.invalidLength};self.version=version;self.key=key;self.fingerprint=SHA256.hash(data:key).map{String(format:"%02x",$0)}.joined()} }
public final class VaultRootKeyManager: @unchecked Sendable {
 public let descriptor:VaultKeyDescriptor; private let store:VaultKeyStoring;private let random:VaultRandomBytesGenerating
 public init(configuration:VaultCryptoConfiguration,store:VaultKeyStoring=VaultKeychainStore(),random:VaultRandomBytesGenerating=SystemVaultRandomBytes()){self.store=store;self.random=random;self.descriptor=VaultKeyDescriptor(service:"com.hsanabria.luna.vault.keys",account:configuration.vaultID,accessGroup:configuration.keychainAccessGroup,synchronizable:true,accessibility:.whenUnlocked)}
 public func loadRequired()throws->VaultRootKey{guard let d=try store.data(for:descriptor)else{throw VaultCryptoError.missingRootKey};return try decode(d)}
 public func loadOrCreate()throws->VaultRootKey{if let d=try store.data(for:descriptor){return try decode(d)};let r=try VaultRootKey(version:1,key:random.bytes(count:32));try store.setData(try JSONEncoder().encode([r]),for:descriptor);return r}
 public func rotate()throws->VaultRootKey{let old=try loadRequired();let n=try VaultRootKey(version:old.version+1,key:random.bytes(count:32));var ring=try decodeRing(store.data(for:descriptor));ring.append(n);try store.setData(try JSONEncoder().encode(ring),for:descriptor);return n}
 public func key(version:UInt32)throws->VaultRootKey{guard let k=try decodeRing(store.data(for:descriptor)).last(where:{$0.version==version})else{throw VaultCryptoError.missingRootKey};return k}
 private func decodeRing(_ d:Data?)throws->[VaultRootKey]{guard let d else{throw VaultCryptoError.missingRootKey};guard let r=try? JSONDecoder().decode([VaultRootKey].self,from:d),!r.isEmpty,r.allSatisfy({$0.key.count==32})else{throw VaultCryptoError.corruptRootKey};return r}
 private func decode(_ d:Data)throws->VaultRootKey{try decodeRing(d).last!}
}
public enum VaultEnvelopeRole:UInt8,Codable,Sendable{case content=1;case metadata=2;case index=3;case dek=4}
public struct VaultChunkEnvelope:Sendable,Equatable{public static let version:UInt8=1;public let role:VaultEnvelopeRole;public let rootVersion:UInt32;public let objectID:VaultObjectID;public let revision:UUID;public let chunkIndex:UInt32;public let plaintextLength:UInt64;public let nonce:Data;public let ciphertext:Data;public init(role:VaultEnvelopeRole,rootVersion:UInt32,objectID:VaultObjectID,revision:UUID,chunkIndex:UInt32,plaintextLength:UInt64,nonce:Data,ciphertext:Data){self.role=role;self.rootVersion=rootVersion;self.objectID=objectID;self.revision=revision;self.chunkIndex=chunkIndex;self.plaintextLength=plaintextLength;self.nonce=nonce;self.ciphertext=ciphertext}
 public func encoded()throws->Data{guard nonce.count==12 else{throw VaultCryptoError.malformedEnvelope};var d=Data([Self.version,role.rawValue]);d.append(contentsOf:bytes(rootVersion));d.append(objectID.rawValue.uuidData);d.append(revision.uuidData);d.append(contentsOf:bytes(chunkIndex));d.append(contentsOf:bytes(plaintextLength));d.append(nonce);d.append(ciphertext);return d}
 public static func decode(_ d:Data)throws->VaultChunkEnvelope{guard d.count>=2+4+16+16+4+8+12+16,d[0]==version,let role=VaultEnvelopeRole(rawValue:d[1])else{throw VaultCryptoError.malformedEnvelope};var i=2;let root=try read32(d,&i);let oid=try readUUID(d,&i);let rev=try readUUID(d,&i);let idx=try read32(d,&i);let len=try read64(d,&i);let n=d[i..<i+12];i+=12;return VaultChunkEnvelope(role:role,rootVersion:root,objectID:VaultObjectID(rawValue:oid),revision:rev,chunkIndex:idx,plaintextLength:len,nonce:Data(n),ciphertext:Data(d[i...]))}
}
public struct VaultSealedObject:Sendable,Equatable{public let objectID:VaultObjectID;public let revision:UUID;public let rootVersion:UInt32;public let wrappedDEK:Data;public let chunks:[Data];public init(objectID:VaultObjectID,revision:UUID,rootVersion:UInt32,wrappedDEK:Data,chunks:[Data]){self.objectID=objectID;self.revision=revision;self.rootVersion=rootVersion;self.wrappedDEK=wrappedDEK;self.chunks=chunks}}
public struct VaultChunkedCryptor:Sendable{public let chunkSize:Int;private let random:VaultRandomBytesGenerating;public init(chunkSize:Int=1_048_576,random:VaultRandomBytesGenerating=SystemVaultRandomBytes()){self.chunkSize=max(1,chunkSize);self.random=random}
 public func seal(_ p:Data,objectID:VaultObjectID,revision:UUID,root:VaultRootKey,role:VaultEnvelopeRole = .content)throws->[Data]{let dek=try random.bytes(count:32);let wrapped=try wrap(dek,root,objectID,revision);var out=[wrapped];let key=SymmetricKey(data:dek);var off=0;var idx:UInt32=0;while off<p.count || (p.isEmpty&&idx==0){let end=min(p.count,off+chunkSize);let part=p[off..<end];let nd=try random.bytes(count:12);let aad=try aad(role,root.version,objectID,revision,idx,UInt64(p.count));let box=try AES.GCM.seal(Data(part),using:key,nonce:try AES.GCM.Nonce(data:nd),authenticating:aad);out.append(try VaultChunkEnvelope(role:role,rootVersion:root.version,objectID:objectID,revision:revision,chunkIndex:idx,plaintextLength:UInt64(p.count),nonce:nd,ciphertext:box.ciphertext+box.tag).encoded());off=end;idx+=1};return out}
 public func open(_ chunks:[Data],objectID:VaultObjectID,revision:UUID,rootKey:(UInt32)throws->VaultRootKey)throws->Data{guard chunks.count>1 else{throw VaultCryptoError.malformedEnvelope};let first=try VaultChunkEnvelope.decode(chunks[1]);let root=try rootKey(first.rootVersion);let dek=try unwrap(chunks[0],root,objectID,revision);let key=SymmetricKey(data:dek);var out=Data();for n in 0..<(chunks.count-1){let c=try VaultChunkEnvelope.decode(chunks[n+1]);guard c.chunkIndex==UInt32(n),c.objectID==objectID else{throw VaultCryptoError.wrongObject};guard c.revision==revision else{throw VaultCryptoError.wrongRevision};let a=try aad(c.role,c.rootVersion,objectID,revision,c.chunkIndex,c.plaintextLength);guard c.ciphertext.count>=16 else{throw VaultCryptoError.malformedEnvelope};let b=try AES.GCM.SealedBox(nonce:try AES.GCM.Nonce(data:c.nonce),ciphertext:c.ciphertext.dropLast(16),tag:c.ciphertext.suffix(16));do{out.append(try AES.GCM.open(b,using:key,authenticating:a))}catch{throw VaultCryptoError.authenticationFailed}};return out}
 public func planRange(_ range:Range<Int>,plaintextLength:Int)throws->Range<Int>{guard range.lowerBound>=0,range.upperBound<=plaintextLength,range.lowerBound<=range.upperBound else{throw VaultCryptoError.invalidRange};return (range.lowerBound/chunkSize)..<((max(range.upperBound,range.lowerBound+1)-1)/chunkSize+1)}
 private func wrap(_ d:Data,_ r:VaultRootKey,_ o:VaultObjectID,_ v:UUID)throws->Data{let n=try random.bytes(count:12);let a=try aad(.dek,r.version,o,v,0,32);let b=try AES.GCM.seal(d,using:SymmetricKey(data:r.key),nonce:try AES.GCM.Nonce(data:n),authenticating:a);return Data([1])+n+b.ciphertext+b.tag}
 private func unwrap(_ d:Data,_ r:VaultRootKey,_ o:VaultObjectID,_ v:UUID)throws->Data{guard d.count>=61 else{throw VaultCryptoError.malformedEnvelope};let b=try AES.GCM.SealedBox(nonce:try AES.GCM.Nonce(data:d[1..<13]),ciphertext:d[13..<d.count-16],tag:d.suffix(16));do{return try AES.GCM.open(b,using:SymmetricKey(data:r.key),authenticating:try aad(.dek,r.version,o,v,0,32))}catch{throw VaultCryptoError.authenticationFailed}}
 private func aad(_ role:VaultEnvelopeRole,_ r:UInt32,_ o:VaultObjectID,_ v:UUID,_ i:UInt32,_ l:UInt64)throws->Data{var d=Data("LunaVault".utf8);d.append(role.rawValue);d.append(contentsOf:bytes(r));d.append(o.rawValue.uuidData);d.append(v.uuidData);d.append(contentsOf:bytes(i));d.append(contentsOf:bytes(l));return d}}
public extension UUID{var uuidData:Data{var u=self.uuid;return Data(bytes:&u,count:16)}}
private func bytes<T:FixedWidthInteger>(_ v:T)->[UInt8]{withUnsafeBytes(of:v.bigEndian){Array($0)}}
private func read32(_ d:Data,_ i:inout Int)throws->UInt32{guard i+4<=d.count else{throw VaultCryptoError.malformedEnvelope};let v=d[i..<i+4].reduce(UInt32(0)){($0<<8)|UInt32($1)};i+=4;return v}
private func read64(_ d:Data,_ i:inout Int)throws->UInt64{guard i+8<=d.count else{throw VaultCryptoError.malformedEnvelope};let v=d[i..<i+8].reduce(UInt64(0)){($0<<8)|UInt64($1)};i+=8;return v}
private func readUUID(_ d:Data,_ i:inout Int)throws->UUID{guard i+16<=d.count else{throw VaultCryptoError.malformedEnvelope};let a=Array(d[i..<i+16]);i+=16;return UUID(uuid:(a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7],a[8],a[9],a[10],a[11],a[12],a[13],a[14],a[15]))}
