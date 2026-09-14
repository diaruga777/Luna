import Foundation

/// One device's counter in a version vector. `id` is a short device ID.
public struct VersionCounter: Hashable, Sendable, Codable {
    public var id: UInt64
    public var value: UInt64
    public init(id: UInt64, value: UInt64) {
        self.id = id
        self.value = value
    }
}

public enum VersionOrdering: Equatable, Sendable {
    case equal
    case greater
    case lesser
    case concurrentGreater
    case concurrentLesser
}

/// Syncthing's version vector (`claudedocs/vault-bep-reference.md` §C).
/// Counters stay sorted by id.
public struct VersionVector: Hashable, Sendable, Codable {
    public private(set) var counters: [VersionCounter]

    public init(counters: [VersionCounter] = []) {
        self.counters = counters.sorted { $0.id < $1.id }
    }

    public static let empty = VersionVector()

    public var isEmpty: Bool { counters.isEmpty }

    public func value(for id: UInt64) -> UInt64 {
        counters.first(where: { $0.id == id })?.value ?? 0
    }

    /// Returns a copy with `id`'s counter raised to `max(old + 1, now)`.
    public func updated(by id: UInt64, now: Date = Date()) -> VersionVector {
        let unix = UInt64(max(0, now.timeIntervalSince1970))
        var copy = self
        if let index = copy.counters.firstIndex(where: { $0.id == id }) {
            copy.counters[index].value = max(copy.counters[index].value + 1, unix)
        } else {
            copy.counters.append(VersionCounter(id: id, value: max(1, unix)))
            copy.counters.sort { $0.id < $1.id }
        }
        return copy
    }

    /// Element-wise maximum.
    public func merged(with other: VersionVector) -> VersionVector {
        var result: [UInt64: UInt64] = [:]
        for counter in counters { result[counter.id] = counter.value }
        for counter in other.counters { result[counter.id] = max(result[counter.id] ?? 0, counter.value) }
        return VersionVector(counters: result.map { VersionCounter(id: $0.key, value: $0.value) })
    }

    public func compare(_ other: VersionVector) -> VersionOrdering {
        var greater = false
        var lesser = false
        var ids = Set(counters.map(\.id))
        ids.formUnion(other.counters.map(\.id))
        for id in ids {
            let a = value(for: id)
            let b = other.value(for: id)
            if a > b { greater = true }
            if a < b { lesser = true }
        }
        switch (greater, lesser) {
        case (false, false): return .equal
        case (true, false): return .greater
        case (false, true): return .lesser
        case (true, true):
            return tiebreak(other) ? .concurrentGreater : .concurrentLesser
        }
    }

    /// Deterministic order for concurrent vectors: the vector whose first
    /// differing counter (by ascending id) is larger wins.
    private func tiebreak(_ other: VersionVector) -> Bool {
        let ids = Set(counters.map(\.id)).union(other.counters.map(\.id)).sorted()
        for id in ids {
            let a = value(for: id)
            let b = other.value(for: id)
            if a != b { return a > b }
        }
        return false
    }

    public var isConcurrent: (VersionVector) -> Bool {
        { other in
            switch compare(other) {
            case .concurrentGreater, .concurrentLesser: return true
            default: return false
            }
        }
    }

    // MARK: Wire

    func encodedProtobuf() -> Data {
        var writer = ProtobufWriter()
        for counter in counters {
            var inner = ProtobufWriter()
            inner.writeVarint(1, counter.id)
            inner.writeVarint(2, counter.value)
            writer.writeMessage(1, inner.data, forceEmpty: true)
        }
        return writer.data
    }

    init(protobuf data: Data) throws {
        var reader = ProtobufReader(data)
        var counters: [VersionCounter] = []
        while let tag = try reader.nextTag() {
            if tag.field == 1, tag.type == .lengthDelimited {
                var inner = ProtobufReader(try reader.readBytes())
                var counter = VersionCounter(id: 0, value: 0)
                while let innerTag = try inner.nextTag() {
                    switch (innerTag.field, innerTag.type) {
                    case (1, .varint): counter.id = try inner.readVarint()
                    case (2, .varint): counter.value = try inner.readVarint()
                    default: try inner.skip(innerTag.type)
                    }
                }
                counters.append(counter)
            } else {
                try reader.skip(tag.type)
            }
        }
        self.init(counters: counters)
    }

    /// Stable binary form for database storage: the protobuf encoding.
    public var storageBytes: Data { encodedProtobuf() }

    public init(storageBytes: Data) throws {
        try self.init(protobuf: storageBytes)
    }
}
