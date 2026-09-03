import Foundation

/// A small least-recently-used cache. The segmenters and the tagger key on
/// paragraph text, so a paragraph that only moved keeps its answer.
struct LRUCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    private let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int { storage.count }

    mutating func value(for key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        if storage[key] == nil, let index = order.firstIndex(of: key) { order.remove(at: index) }
        else if let index = order.firstIndex(of: key) { order.remove(at: index) }
        storage[key] = value
        order.append(key)
        while order.count > limit {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
    }

    mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
    }
}
