import Foundation

/// A small least-recently-used cache. The segmenters and the tagger key on
/// paragraph text, so a paragraph that only moved keeps its answer.
///
/// Recency is a stamp on each entry, not a position in an ordered list: a
/// hit is one dictionary write, never a scan-and-shift over every key.
struct LRUCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var stamp: Int
    }

    private var storage: [Key: Entry] = [:]
    private var clock = 0
    private let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int { storage.count }

    mutating func value(for key: Key) -> Value? {
        guard let entry = storage[key] else { return nil }
        clock += 1
        storage[key] = Entry(value: entry.value, stamp: clock)
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key) {
        clock += 1
        storage[key] = Entry(value: value, stamp: clock)
        guard storage.count > limit else { return }
        if let stalest = storage.min(by: { $0.value.stamp < $1.value.stamp })?.key {
            storage.removeValue(forKey: stalest)
        }
    }

    mutating func removeAll() {
        storage.removeAll()
        clock = 0
    }
}
