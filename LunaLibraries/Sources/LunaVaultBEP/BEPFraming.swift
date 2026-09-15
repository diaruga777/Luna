import Foundation

/// The BEP frame layout (`claudedocs/vault-bep-reference.md` §A.2, §A.3).
public enum BEPFraming {
    public static let helloMagic: UInt32 = 0x2EA7_D90B
    public static let maximumHelloBytes = 32767
    public static let maximumMessageBytes = 500_000_000

    public static func encodeHello(_ hello: BEPHello) throws -> Data {
        let body = hello.encoded()
        guard body.count <= maximumHelloBytes else { throw BEPProtocolError.helloTooLarge(body.count) }
        var data = Data(capacity: 6 + body.count)
        data.append(bigEndian: helloMagic)
        data.append(bigEndian: UInt16(body.count))
        data.append(body)
        return data
    }

    public static func readHello(from stream: any BEPByteStream) async throws -> BEPHello {
        let prefix = try await stream.read(exactly: 6)
        let magic = prefix.bigEndianUInt32(at: 0)
        guard magic == helloMagic else { throw BEPProtocolError.badMagic(magic) }
        let length = Int(prefix.bigEndianUInt16(at: 4))
        guard length <= maximumHelloBytes else { throw BEPProtocolError.helloTooLarge(length) }
        let body = length == 0 ? Data() : try await stream.read(exactly: length)
        return try BEPHello(protobuf: body)
    }

    /// Frames one message. Luna never compresses what it sends.
    public static func encodeMessage(_ message: BEPMessage) -> Data {
        let body = message.encodedBody()
        let header = BEPHeader(type: message.type ?? .ping, compression: .none).encoded()
        var data = Data(capacity: 6 + header.count + body.count)
        data.append(bigEndian: UInt16(header.count))
        data.append(header)
        data.append(bigEndian: UInt32(body.count))
        data.append(body)
        return data
    }

    /// Reads and decodes one message, decompressing LZ4 when flagged.
    public static func readMessage(from stream: any BEPByteStream) async throws -> BEPMessage {
        let headerLengthBytes = try await stream.read(exactly: 2)
        let headerLength = Int(headerLengthBytes.bigEndianUInt16(at: 0))
        guard headerLength <= 0x7FFF else { throw BEPProtocolError.messageTooLarge(headerLength) }
        let header = try BEPHeader(protobuf: headerLength == 0 ? Data() : try await stream.read(exactly: headerLength))
        let lengthBytes = try await stream.read(exactly: 4)
        let length = Int(lengthBytes.bigEndianUInt32(at: 0))
        guard length <= maximumMessageBytes else { throw BEPProtocolError.messageTooLarge(length) }
        var body = length == 0 ? Data() : try await stream.read(exactly: length)
        if header.compression == .lz4 {
            guard body.count >= 4 else { throw BEPProtocolError.lz4("short container") }
            let uncompressed = Int(body.bigEndianUInt32(at: 0))
            guard uncompressed <= maximumMessageBytes else { throw BEPProtocolError.messageTooLarge(uncompressed) }
            body = try LZ4Block.decode(Data(body.dropFirst(4)), uncompressedLength: uncompressed)
        }
        return try BEPMessage.decode(type: header.type, rawType: header.rawType, body: body)
    }
}

/// The LZ4 block format (`§J.2`). Decode only.
public enum LZ4Block {
    public static func decode(_ src: Data, uncompressedLength: Int) throws -> Data {
        var dst = [UInt8](repeating: 0, count: uncompressedLength)
        var pos = 0
        try src.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let s = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = s.count
            if n == 0 {
                guard uncompressedLength == 0 else { throw BEPProtocolError.lz4("empty block") }
                return
            }
            while true {
                guard i < n else { throw BEPProtocolError.lz4("truncated token") }
                let token = s[i]; i += 1
                var literalLength = Int(token >> 4)
                if literalLength == 15 {
                    while true {
                        guard i < n else { throw BEPProtocolError.lz4("truncated literal length") }
                        let b = s[i]; i += 1
                        literalLength += Int(b)
                        if b != 255 { break }
                    }
                }
                guard i + literalLength <= n, pos + literalLength <= uncompressedLength else {
                    throw BEPProtocolError.lz4("literal overrun")
                }
                if literalLength > 0 {
                    dst.withUnsafeMutableBufferPointer { d in
                        _ = memcpy(d.baseAddress! + pos, raw.baseAddress! + i, literalLength)
                    }
                    pos += literalLength
                    i += literalLength
                }
                if i == n { break }
                guard i + 2 <= n else { throw BEPProtocolError.lz4("truncated offset") }
                let offset = Int(s[i]) | (Int(s[i + 1]) << 8)
                i += 2
                guard offset > 0, offset <= pos else { throw BEPProtocolError.lz4("bad offset") }
                var matchLength = Int(token & 0x0F) + 4
                if (token & 0x0F) == 15 {
                    while true {
                        guard i < n else { throw BEPProtocolError.lz4("truncated match length") }
                        let b = s[i]; i += 1
                        matchLength += Int(b)
                        if b != 255 { break }
                    }
                }
                guard pos + matchLength <= uncompressedLength else { throw BEPProtocolError.lz4("match overrun") }
                var from = pos - offset
                for _ in 0..<matchLength {
                    dst[pos] = dst[from]
                    pos += 1
                    from += 1
                }
            }
        }
        guard pos == uncompressedLength else { throw BEPProtocolError.lz4("length mismatch \(pos) != \(uncompressedLength)") }
        return Data(dst)
    }
}

extension Data {
    mutating func append(bigEndian value: UInt16) {
        append(UInt8(value >> 8)); append(UInt8(value & 0xFF))
    }

    mutating func append(bigEndian value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }

    func bigEndianUInt16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func bigEndianUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}
