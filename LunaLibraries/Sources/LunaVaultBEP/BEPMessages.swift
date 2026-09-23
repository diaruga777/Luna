import Foundation

/// BEP message schemas (`claudedocs/vault-bep-reference.md` §A.5). Field
/// numbers are the wire contract; `BEPMessageCodecTests` pins golden bytes.

public enum BEPMessageType: Int, Sendable {
    case clusterConfig = 0
    case index = 1
    case indexUpdate = 2
    case request = 3
    case response = 4
    case downloadProgress = 5
    case ping = 6
    case close = 7
}

public enum BEPCompression: Int, Sendable {
    case none = 0
    case lz4 = 1
}

public struct BEPHeader: Equatable, Sendable {
    public var type: BEPMessageType?
    public var rawType: Int
    public var compression: BEPCompression

    public init(type: BEPMessageType, compression: BEPCompression = .none) {
        self.type = type
        rawType = type.rawValue
        self.compression = compression
    }

    init(rawType: Int, compression: BEPCompression) {
        self.rawType = rawType
        type = BEPMessageType(rawValue: rawType)
        self.compression = compression
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.writeVarint(1, UInt64(rawType))
        writer.writeVarint(2, UInt64(compression.rawValue))
        return writer.data
    }

    public init(protobuf data: Data) throws {
        var reader = ProtobufReader(data)
        var rawType = 0
        var compression = 0
        while let tag = try reader.nextTag() {
            switch (tag.field, tag.type) {
            case (1, .varint): rawType = Int(try reader.readVarint())
            case (2, .varint): compression = Int(try reader.readVarint())
            default: try reader.skip(tag.type)
            }
        }
        guard let comp = BEPCompression(rawValue: compression) else { throw BEPProtocolError.unknownCompression(compression) }
        self.init(rawType: rawType, compression: comp)
    }
}

public enum BEPProtocolError: Error, Equatable {
    case badMagic(UInt32)
    case helloTooLarge(Int)
    case messageTooLarge(Int)
    case unknownCompression(Int)
    case lz4(String)
    case clusterConfigExpected
    case closedByPeer(String)
    case receiveTimeout
    case invalidFileName(String)
    case invalidFileInfo(String)
    case invalidRequest(String)
}

// MARK: - Hello

public struct BEPHello: Equatable, Sendable {
    public var deviceName: String
    public var clientName: String
    public var clientVersion: String
    public var numConnections: Int32
    public var timestamp: Int64

    public init(deviceName: String, clientName: String, clientVersion: String,
                numConnections: Int32 = 1, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000)) {
        self.deviceName = deviceName
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.numConnections = numConnections
        self.timestamp = timestamp
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.writeString(1, deviceName)
        writer.writeString(2, clientName)
        writer.writeString(3, clientVersion)
        writer.writeInt32(4, numConnections)
        writer.writeInt64(5, timestamp)
        return writer.data
    }

    public init(protobuf data: Data) throws {
        var reader = ProtobufReader(data)
        var hello = BEPHello(deviceName: "", clientName: "", clientVersion: "", numConnections: 0, timestamp: 0)
        while let tag = try reader.nextTag() {
            switch (tag.field, tag.type) {
            case (1, .lengthDelimited): hello.deviceName = try reader.readString()
            case (2, .lengthDelimited): hello.clientName = try reader.readString()
            case (3, .lengthDelimited): hello.clientVersion = try reader.readString()
            case (4, .varint): hello.numConnections = try reader.readInt32()
            case (5, .varint): hello.timestamp = try reader.readInt64()
            default: try reader.skip(tag.type)
            }
        }
        self = hello
    }
}

// MARK: - ClusterConfig

public enum BEPFolderType: Int, Sendable {
    case sendReceive = 0
    case sendOnly = 1
    case receiveOnly = 2
    case receiveEncrypted = 3
}

public enum BEPCompressionPolicy: Int, Sendable {
    case metadata = 0
    case never = 1
    case always = 2
}

public struct BEPDevice: Equatable, Sendable {
    public var id: DeviceID
    public var name: String
    public var addresses: [String]
    public var compression: BEPCompressionPolicy
    public var certName: String
    public var maxSequence: Int64
    public var introducer: Bool
    public var indexID: UInt64
    public var skipIntroductionRemovals: Bool
    public var encryptionPasswordToken: Data

    public init(id: DeviceID, name: String = "", addresses: [String] = [], compression: BEPCompressionPolicy = .metadata,
                certName: String = "", maxSequence: Int64 = 0, introducer: Bool = false, indexID: UInt64 = 0,
                skipIntroductionRemovals: Bool = false, encryptionPasswordToken: Data = Data()) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.compression = compression
        self.certName = certName
        self.maxSequence = maxSequence
        self.introducer = introducer
        self.indexID = indexID
        self.skipIntroductionRemovals = skipIntroductionRemovals
        self.encryptionPasswordToken = encryptionPasswordToken
    }

    func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.writeBytes(1, id.bytes)
        writer.writeString(2, name)
        for address in addresses { writer.writeString(3, address) }
        writer.writeVarint(4, UInt64(compression.rawValue))
        writer.writeString(5, certName)
        writer.writeInt64(6, maxSequence)
        writer.writeBool(7, introducer)
        writer.writeVarint(8, indexID)
        writer.writeBool(9, skipIntroductionRemovals)
        writer.writeBytes(10, encryptionPasswordToken)
        return writer.data
    }

    init(protobuf data: Data) throws {
        var reader = ProtobufReader(data)
        var idBytes = Data()
        var device = BEPDevice(id: try DeviceID(bytes: Data(repeating: 0, count: 32)))
        while let tag = try reader.nextTag() {
            switch (tag.field, tag.type) {
            case (1, .lengthDelimited): idBytes = try reader.readBytes()
            case (2, .lengthDelimited): device.name = try reader.readString()
            case (3, .lengthDelimited): device.addresses.append(try reader.readString())
            case (4, .varint): device.compression = BEPCompressionPolicy(rawValue: Int(try reader.readVarint())) ?? .metadata
            case (5, .lengthDelimited): device.certName = try reader.readString()
            case (6, .varint): device.maxSequence = try reader.readInt64()
            case (7, .varint): device.introducer = try reader.readBool()
            case (8, .varint): device.indexID = try reader.readVarint()
            case (9, .varint): device.skipIntroductionRemovals = try reader.readBool()
            case (10, .lengthDelimited): device.encryptionPasswordToken = try reader.readBytes()
            default: try reader.skip(tag.type)
            }
        }
        device.id = try DeviceID(bytes: idBytes)
        self = device
    }
}

public struct BEPFolder: Equatable, Sendable {
    public var id: String
    public var label: String
    public var type: BEPFolderType
    public var paused: Bool
    public var devices: [BEPDevice]

    public init(id: String, label: String, type: BEPFolderType = .sendReceive, paused: Bool = false, devices: [BEPDevice]) {
        self.id = id
        self.label = label
        self.type = type
        self.paused = paused
        self.devices = devices
    }

    func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.writeString(1, id)
        writer.writeString(2, label)
        writer.writeVarint(3, UInt64(type.rawValue))
        writer.writeVarint(7, paused ? 1 : 0)
        for device in devices { writer.writeMessage(16, device.encoded(), forceEmpty: true) }
        return writer.data
    }

    init(protobuf data: Data) throws {
        var reader = ProtobufReader(data)
        var folder = BEPFolder(id: "", label: "", devices: [])
        while let tag = try reader.nextTag() {
            switch (tag.field, tag.type) {
            case (1, .lengthDelimited): folder.id = try reader.readString()
            case (2, .lengthDelimited): folder.label = try reader.readString()
            case (3, .varint): folder.type = BEPFolderType(rawValue: Int(try reader.readVarint())) ?? .sendReceive
            case (7, .varint): folder.paused = try reader.readVarint() != 0
            case (16, .lengthDelimited): folder.devices.append(try BEPDevice(protobuf: try reader.readBytes()))
            default: try reader.skip(tag.type)
            }
        }
        self = folder
    }
}

public struct BEPClusterConfig: Equatable, Sendable {
    public var folders: [BEPFolder]
    public var secondary: Bool

    public init(folders: [BEPFolder], secondary: Bool = false) {
        self.folders = folders
        self.secondary = secondary
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        for folder in folders { writer.writeMessage(1, folder.encoded(), forceEmpty: true) }
        writer.writeBool(2, secondary)
        return writer.data
    }

    public init(protobuf data: Data) throws {
        var reader = ProtobufReader(data)
        var config = BEPClusterConfig(folders: [])
        while let tag = try reader.nextTag() {
            switch (tag.field, tag.type) {
            case (1, .lengthDelimited): config.folders.append(try BEPFolder(protobuf: try reader.readBytes()))
            case (2, .varint): config.secondary = try reader.readBool()
            default: try reader.skip(tag.type)
            }
        }
        self = config
    }
}

// MARK: - FileInfo

public enum BEPFileType: Int, Sendable, Codable {
    case file = 0
    case directory = 1
    case symlink = 4

    init(wire raw: Int) {
        switch raw {
        case 1: self = .directory
        case 2, 3, 4: self = .symlink
        default: self = .file
        }
    }
}

public struct BEPFileInfo: Equatable, Sendable {
    public var name: String
    public var type: BEPFileType
    public var size: Int64
    public var permissions: UInt32
    public var modifiedS: Int64
    public var modifiedNs: Int32
    public var modifiedBy: UInt64
    public var deleted: Bool
    public var invalid: Bool
    public var noPermissions: Bool
    public var version: VersionVector
    public var sequence: Int64
    public var blockSize: Int32
    public var blocks: [BlockInfo]
    public var symlinkTarget: Data
    public var blocksHash: Data
    public var previousBlocksHash: Data

    public init(name: String, type: BEPFileType = .file, size: Int64 = 0, permissions: UInt32 = 0,
                modifiedS: Int64 = 0, modifiedNs: Int32 = 0, modifiedBy: UInt64 = 0, deleted: Bool = false,
                invalid: Bool = false, noPermissions: Bool = false, version: VersionVector = .empty, sequence: Int64 = 0,
                blockSize: Int32 = 0, blocks: [BlockInfo] = [], symlinkTarget: Data = Data(), blocksHash: Data = Data(),
                previousBlocksHash: Data = Data()) {
        self.name = name
        self.type = type
        self.size = size
        self.permissions = permissions
        self.modifiedS = modifiedS
        self.modifiedNs = modifiedNs
        self.modifiedBy = modifiedBy
        self.deleted = deleted
        self.invalid = invalid
        self.noPermissions = noPermissions
        self.version = version
        self.sequence = sequence
        self.blockSize = blockSize
        self.blocks = blocks
        self.symlinkTarget = symlinkTarget
        self.blocksHash = blocksHash
        self.previousBlocksHash = previousBlocksHash
    }

    /// The modification time as a date.
    public var modified: Date {
        Date(timeIntervalSince1970: TimeInterval(modifiedS) + TimeInterval(modifiedNs) / 1_000_000_000)
    }

    /// `block_size` 0 means 128 KiB on the wire.
    public var effectiveBlockSize: Int {
        blockSize == 0 ? BlockLayout.minimumBlockSize : Int(blockSize)
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.writeString(1, name)
        writer.writeVarint(2, UInt64(type.rawValue))
        writer.writeInt64(3, size)
        writer.writeUInt32(4, permissions)
        writer.writeInt64(5, modifiedS)
        writer.writeBool(6, deleted)
        writer.writeBool(7, invalid)
        writer.writeBool(8, noPermissions)
        writer.writeMessage(9, version.encodedProtobuf())
        writer.writeInt64(10, sequence)
        writer.writeInt32(11, modifiedNs)
        writer.writeVarint(12, modifiedBy)
        writer.writeInt32(13, blockSize)
        for block in blocks {
            var inner = ProtobufWriter()
            inner.writeInt64(1, block.offset)
            inner.writeInt32(2, block.size)
            inner.writeBytes(3, block.hash)
            writer.writeMessage(16, inner.data, forceEmpty: true)
        }
        writer.writeBytes(17, symlinkTarget)
        writer.writeBytes(18, blocksHash)
        writer.writeBytes(20, previousBlocksHash)
        return writer.data
    }

    public init(protobuf data: Data) throws {
        var reader = ProtobufReader(data)
        var info = BEPFileInfo(name: "")
        while let tag = try reader.nextTag() {
            switch (tag.field, tag.type) {
            case (1, .lengthDelimited): info.name = try reader.readString()
            case (2, .varint): info.type = BEPFileType(wire: Int(try reader.readVarint()))
            case (3, .varint): info.size = try reader.readInt64()
            case (4, .varint): info.permissions = try reader.readUInt32()
            case (5, .varint): info.modifiedS = try reader.readInt64()
            case (6, .varint): info.deleted = try reader.readBool()
            case (7, .varint): info.invalid = try reader.readBool()
            case (8, .varint): info.noPermissions = try reader.readBool()
            case (9, .lengthDelimited): info.version = try VersionVector(protobuf: try reader.readBytes())
            case (10, .varint): info.sequence = try reader.readInt64()
            case (11, .varint): info.modifiedNs = try reader.readInt32()
            case (12, .varint): info.modifiedBy = try reader.readVarint()
            case (13, .varint): info.blockSize = try reader.readInt32()
            case (16, .lengthDelimited):
                var inner = ProtobufReader(try reader.readBytes())
                var block = BlockInfo(offset: 0, size: 0, hash: Data())
                while let innerTag = try inner.nextTag() {
                    switch (innerTag.field, innerTag.type) {
                    case (1, .varint): block.offset = try inner.readInt64()
                    case (2, .varint): block.size = try inner.readInt32()
                    case (3, .lengthDelimited): block.hash = try inner.readBytes()
                    default: try inner.skip(innerTag.type)
                    }
                }
                info.blocks.append(block)
            case (17, .lengthDelimited): info.symlinkTarget = try reader.readBytes()
            case (18, .lengthDelimited): info.blocksHash = try reader.readBytes()
            case (20, .lengthDelimited): info.previousBlocksHash = try reader.readBytes()
            default: try reader.skip(tag.type)
            }
        }
        self = info
    }

    /// The checks a Syncthing peer applies before accepting an entry
    /// (`§A.4`). Throws so the sender fails locally instead of being
    /// disconnected.
    public func validateForWire() throws {
        try BEPFileInfo.validateName(name)
        if deleted && !blocks.isEmpty { throw BEPProtocolError.invalidFileInfo("deleted entry has blocks") }
        if type != .file && !blocks.isEmpty { throw BEPProtocolError.invalidFileInfo("non-file has blocks") }
        if type != .file && size != 0 { throw BEPProtocolError.invalidFileInfo("non-file has size") }
        if type == .file && !deleted && !invalid && blocks.isEmpty { throw BEPProtocolError.invalidFileInfo("file has no blocks") }
    }

    public static func validateName(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." { throw BEPProtocolError.invalidFileName(name) }
        if name.hasPrefix("/") || name.hasPrefix("../") || name.hasSuffix("/") { throw BEPProtocolError.invalidFileName(name) }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { throw BEPProtocolError.invalidFileName(name) }
        if name.precomposedStringWithCanonicalMapping != name { throw BEPProtocolError.invalidFileName(name) }
    }
}

// MARK: - Index / IndexUpdate

public struct BEPIndex: Equatable, Sendable {
    public var folder: String
    public var files: [BEPFileInfo]
    public var lastSequence: Int64
    public var prevSequence: Int64
    public var isUpdate: Bool

    public init(folder: String, files: [BEPFileInfo], lastSequence: Int64 = 0, prevSequence: Int64 = 0, isUpdate: Bool) {
        self.folder = folder
        self.files = files
        self.lastSequence = lastSequence
        self.prevSequence = prevSequence
        self.isUpdate = isUpdate
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.writeString(1, folder)
        for file in files { writer.writeMessage(2, file.encoded(), forceEmpty: true) }
        writer.writeInt64(3, lastSequence)
        if isUpdate { writer.writeInt64(4, prevSequence) }
        return writer.data
    }

    public init(protobuf data: Data, isUpdate: Bool) throws {
        var reader = ProtobufReader(data)
        var index = BEPIndex(folder: "", files: [], isUpdate: isUpdate)
        while let tag = try reader.nextTag() {
            switch (tag.field, tag.type) {
            case (1, .lengthDelimited): index.folder = try reader.readString()
            case (2, .lengthDelimited): index.files.append(try BEPFileInfo(protobuf: try reader.readBytes()))
            case (3, .varint): index.lastSequence = try reader.readInt64()
            case (4, .varint): index.prevSequence = try reader.readInt64()
            default: try reader.skip(tag.type)
            }
        }
        self = index
    }
}

// MARK: - Request / Response

public struct BEPRequest: Equatable, Sendable {
    public var id: Int32
    public var folder: String
    public var name: String
    public var offset: Int64
    public var size: Int32
    public var hash: Data
    public var fromTemporary: Bool
    public var blockNo: Int32

    public init(id: Int32, folder: String, name: String, offset: Int64, size: Int32, hash: Data,
                fromTemporary: Bool = false, blockNo: Int32 = 0) {
        self.id = id
        self.folder = folder
        self.name = name
        self.offset = offset
        self.size = size
        self.hash = hash
        self.fromTemporary = fromTemporary
        self.blockNo = blockNo
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.writeInt32(1, id)
        writer.writeString(2, folder)
        writer.writeString(3, name)
        writer.writeInt64(4, offset)
        writer.writeInt32(5, size)
        writer.writeBytes(6, hash)
        writer.writeBool(7, fromTemporary)
        writer.writeInt32(9, blockNo)
        return writer.data
    }

    public init(protobuf data: Data) throws {
        var reader = ProtobufReader(data)
        var request = BEPRequest(id: 0, folder: "", name: "", offset: 0, size: 0, hash: Data())
        while let tag = try reader.nextTag() {
            switch (tag.field, tag.type) {
            case (1, .varint): request.id = try reader.readInt32()
            case (2, .lengthDelimited): request.folder = try reader.readString()
            case (3, .lengthDelimited): request.name = try reader.readString()
            case (4, .varint): request.offset = try reader.readInt64()
            case (5, .varint): request.size = try reader.readInt32()
            case (6, .lengthDelimited): request.hash = try reader.readBytes()
            case (7, .varint): request.fromTemporary = try reader.readBool()
            case (9, .varint): request.blockNo = try reader.readInt32()
            default: try reader.skip(tag.type)
            }
        }
        self = request
    }

    public func validateForWire() throws {
        if hash.isEmpty { throw BEPProtocolError.invalidRequest("missing block hash") }
        if size < 0 || Int(size) > BlockLayout.maximumRequestSize { throw BEPProtocolError.invalidRequest("size \(size)") }
        if offset < 0 { throw BEPProtocolError.invalidRequest("offset \(offset)") }
        try BEPFileInfo.validateName(name)
    }
}

public enum BEPErrorCode: Int, Sendable, Equatable, Error {
    case noError = 0
    case generic = 1
    case noSuchFile = 2
    case invalidFile = 3
}

public struct BEPResponse: Equatable, Sendable {
    public var id: Int32
    public var data: Data
    public var code: BEPErrorCode
    public var rawCode: Int

    public init(id: Int32, data: Data, code: BEPErrorCode = .noError) {
        self.id = id
        self.data = data
        self.code = code
        rawCode = code.rawValue
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.writeInt32(1, id)
        writer.writeBytes(2, data)
        writer.writeVarint(3, UInt64(rawCode))
        return writer.data
    }

    public init(protobuf data: Data) throws {
        var reader = ProtobufReader(data)
        var response = BEPResponse(id: 0, data: Data())
        while let tag = try reader.nextTag() {
            switch (tag.field, tag.type) {
            case (1, .varint): response.id = try reader.readInt32()
            case (2, .lengthDelimited): response.data = try reader.readBytes()
            case (3, .varint):
                response.rawCode = Int(try reader.readVarint())
                response.code = BEPErrorCode(rawValue: response.rawCode) ?? .generic
            default: try reader.skip(tag.type)
            }
        }
        self = response
    }
}

// MARK: - Close

public struct BEPClose: Equatable, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.writeString(1, reason)
        return writer.data
    }

    public init(protobuf data: Data) throws {
        var reader = ProtobufReader(data)
        var reason = ""
        while let tag = try reader.nextTag() {
            if tag.field == 1, tag.type == .lengthDelimited { reason = try reader.readString() } else { try reader.skip(tag.type) }
        }
        self.init(reason: reason)
    }
}

// MARK: - DownloadProgress

public struct BEPFileDownloadProgressUpdate: Equatable, Sendable {
    public var name: String
    public var version: VersionVector
    public var blockIndexes: [Int]
    public var isForget: Bool

    public init(name: String, version: VersionVector, blockIndexes: [Int], isForget: Bool = false) {
        self.name = name; self.version = version; self.blockIndexes = blockIndexes; self.isForget = isForget
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.writeInt32(1, isForget ? 1 : 0)
        writer.writeString(2, name)
        writer.writeMessage(3, version.encodedProtobuf())
        for index in blockIndexes { writer.writeVarintIncludingZero(4, UInt64(index)) }
        return writer.data
    }

    public init(protobuf data: Data) throws {
        var reader = ProtobufReader(data)
        var name = ""
        var version = VersionVector.empty
        var indexes: [Int] = []
        var forget = false
        while let tag = try reader.nextTag() {
            switch (tag.field, tag.type) {
            case (1, .varint): forget = try reader.readInt32() == 1
            case (2, .lengthDelimited): name = try reader.readString()
            case (3, .lengthDelimited): version = try VersionVector(protobuf: reader.readBytes())
            case (4, .varint): indexes.append(Int(try reader.readInt32()))
            default: try reader.skip(tag.type)
            }
        }
        self.init(name: name, version: version, blockIndexes: indexes, isForget: forget)
    }
}

public struct BEPDownloadProgress: Equatable, Sendable {
    public var folder: String
    public var updates: [BEPFileDownloadProgressUpdate]
    public init(folder: String, updates: [BEPFileDownloadProgressUpdate] = []) {
        self.folder = folder; self.updates = updates
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.writeString(1, folder)
        for update in updates { writer.writeMessage(2, update.encoded()) }
        return writer.data
    }

    public init(protobuf data: Data) throws {
        var reader = ProtobufReader(data)
        var folder = ""
        var updates: [BEPFileDownloadProgressUpdate] = []
        while let tag = try reader.nextTag() {
            switch (tag.field, tag.type) {
            case (1, .lengthDelimited): folder = try reader.readString()
            case (2, .lengthDelimited): updates.append(try BEPFileDownloadProgressUpdate(protobuf: reader.readBytes()))
            default: try reader.skip(tag.type)
            }
        }
        self.init(folder: folder, updates: updates)
    }
}

/// A decoded incoming message.
public enum BEPMessage: Equatable, Sendable {
    case clusterConfig(BEPClusterConfig)
    case index(BEPIndex)
    case request(BEPRequest)
    case response(BEPResponse)
    case downloadProgress(BEPDownloadProgress)
    case ping
    case close(BEPClose)
    /// A type this implementation does not know. Skipped, per §A.3.
    case unknown(rawType: Int)

    public var type: BEPMessageType? {
        switch self {
        case .clusterConfig: return .clusterConfig
        case .index(let index): return index.isUpdate ? .indexUpdate : .index
        case .request: return .request
        case .response: return .response
        case .downloadProgress: return .downloadProgress
        case .ping: return .ping
        case .close: return .close
        case .unknown: return nil
        }
    }

    public func encodedBody() -> Data {
        switch self {
        case .clusterConfig(let config): return config.encoded()
        case .index(let index): return index.encoded()
        case .request(let request): return request.encoded()
        case .response(let response): return response.encoded()
        case .downloadProgress(let progress): return progress.encoded()
        case .ping: return Data()
        case .close(let close): return close.encoded()
        case .unknown: return Data()
        }
    }

    public static func decode(type: BEPMessageType?, rawType: Int, body: Data) throws -> BEPMessage {
        guard let type else { return .unknown(rawType: rawType) }
        switch type {
        case .clusterConfig: return .clusterConfig(try BEPClusterConfig(protobuf: body))
        case .index: return .index(try BEPIndex(protobuf: body, isUpdate: false))
        case .indexUpdate: return .index(try BEPIndex(protobuf: body, isUpdate: true))
        case .request: return .request(try BEPRequest(protobuf: body))
        case .response: return .response(try BEPResponse(protobuf: body))
        case .downloadProgress: return .downloadProgress(try BEPDownloadProgress(protobuf: body))
        case .ping: return .ping
        case .close: return .close(try BEPClose(protobuf: body))
        }
    }
}
