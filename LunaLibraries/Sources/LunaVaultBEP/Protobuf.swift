import Foundation

/// Protocol Buffers wire format, the subset BEP uses: varint, length-delimited,
/// and skipping of unknown fields (`claudedocs/vault-bep-reference.md` §J.1).
public enum ProtobufError: Error, Equatable {
    case truncated
    case malformedVarint
    case unsupportedWireType(UInt8)
    case invalidUTF8
    case lengthOutOfRange(Int)
}

public enum ProtobufWireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

/// Appends fields in field-number order. Zero and empty values are omitted,
/// as proto3 encoders do.
public struct ProtobufWriter {
    public private(set) var data = Data()

    public init() {}

    public static func varintBytes(_ value: UInt64) -> Data {
        var out = Data(capacity: 10)
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    private mutating func tag(_ field: Int, _ type: ProtobufWireType) {
        data.append(ProtobufWriter.varintBytes(UInt64(field << 3) | UInt64(type.rawValue)))
    }

    public mutating func writeVarint(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return }
        tag(field, .varint)
        data.append(ProtobufWriter.varintBytes(value))
    }

    public mutating func writeInt64(_ field: Int, _ value: Int64) {
        writeVarint(field, UInt64(bitPattern: value))
    }

    public mutating func writeInt32(_ field: Int, _ value: Int32) {
        writeVarint(field, UInt64(bitPattern: Int64(value)))
    }

    public mutating func writeUInt32(_ field: Int, _ value: UInt32) {
        writeVarint(field, UInt64(value))
    }

    public mutating func writeBool(_ field: Int, _ value: Bool) {
        writeVarint(field, value ? 1 : 0)
    }

    public mutating func writeBytes(_ field: Int, _ value: Data) {
        guard !value.isEmpty else { return }
        tag(field, .lengthDelimited)
        data.append(ProtobufWriter.varintBytes(UInt64(value.count)))
        data.append(value)
    }

    public mutating func writeString(_ field: Int, _ value: String) {
        writeBytes(field, Data(value.utf8))
    }

    /// Writes an embedded message even when empty, so a caller can emit a
    /// zero-length record where a peer expects the field present.
    public mutating func writeMessage(_ field: Int, _ body: Data, forceEmpty: Bool = false) {
        guard !body.isEmpty || forceEmpty else { return }
        tag(field, .lengthDelimited)
        data.append(ProtobufWriter.varintBytes(UInt64(body.count)))
        data.append(body)
    }
}

/// Walks a message once, handing each field to the caller.
public struct ProtobufReader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    public var isAtEnd: Bool { offset >= data.endIndex }

    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < data.endIndex else { throw ProtobufError.truncated }
            let byte = data[offset]
            offset += 1
            if shift == 63 && byte > 1 { throw ProtobufError.malformedVarint }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw ProtobufError.malformedVarint }
        }
    }

    /// Returns the next field number and wire type, or nil at the end.
    public mutating func nextTag() throws -> (field: Int, type: ProtobufWireType)? {
        guard !isAtEnd else { return nil }
        let key = try readVarint()
        let rawType = UInt8(key & 0x7)
        guard let type = ProtobufWireType(rawValue: rawType) else {
            throw ProtobufError.unsupportedWireType(rawType)
        }
        return (Int(key >> 3), type)
    }

    public mutating func readBytes() throws -> Data {
        let length = try readVarint()
        guard length <= UInt64(data.endIndex - offset) else { throw ProtobufError.truncated }
        let end = offset + Int(length)
        let slice = data[offset..<end]
        offset = end
        return Data(slice)
    }

    public mutating func readString() throws -> String {
        guard let string = String(data: try readBytes(), encoding: .utf8) else {
            throw ProtobufError.invalidUTF8
        }
        return string
    }

    public mutating func readInt64() throws -> Int64 { Int64(bitPattern: try readVarint()) }
    public mutating func readInt32() throws -> Int32 { Int32(truncatingIfNeeded: Int64(bitPattern: try readVarint())) }
    public mutating func readUInt32() throws -> UInt32 { UInt32(truncatingIfNeeded: try readVarint()) }
    public mutating func readBool() throws -> Bool { try readVarint() != 0 }

    /// Reads a repeated scalar varint field in either packed or unpacked form.
    public mutating func readRepeatedVarint(wireType: ProtobufWireType, into values: inout [UInt64]) throws {
        switch wireType {
        case .lengthDelimited:
            var inner = ProtobufReader(try readBytes())
            while !inner.isAtEnd { values.append(try inner.readVarint()) }
        default:
            values.append(try readVarint())
        }
    }

    public mutating func skip(_ type: ProtobufWireType) throws {
        switch type {
        case .varint: _ = try readVarint()
        case .lengthDelimited: _ = try readBytes()
        case .fixed64:
            guard data.endIndex - offset >= 8 else { throw ProtobufError.truncated }
            offset += 8
        case .fixed32:
            guard data.endIndex - offset >= 4 else { throw ProtobufError.truncated }
            offset += 4
        }
    }
}
