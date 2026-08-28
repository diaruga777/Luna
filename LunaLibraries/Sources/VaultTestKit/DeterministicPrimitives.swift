import Foundation
import LunaVaultModels

public final class VaultTestClock: VaultClock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentDate: Date

    public init(now: Date) {
        currentDate = now
    }

    public func now() -> Date {
        lock.withLock { currentDate }
    }

    public func advance(by interval: TimeInterval) {
        lock.withLock {
            currentDate = currentDate.addingTimeInterval(interval)
        }
    }
}

public final class VaultTestUUIDGenerator: VaultUUIDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private let values: [UUID]
    private var index = 0

    public init(values: [UUID]) {
        precondition(!values.isEmpty, "VaultTestUUIDGenerator needs at least one UUID")
        self.values = values
    }

    /// Values repeat after the supplied sequence, keeping long-running tests
    /// deterministic without a hidden system-random fallback.
    public func next() -> UUID {
        lock.withLock {
            let value = values[index % values.count]
            index += 1
            return value
        }
    }
}

public final class VaultTestRandomBytes: VaultRandomBytesGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public func bytes(count: Int) throws -> Data {
        guard count >= 0 else { throw VaultScaffoldError.invalidByteCount(count) }
        return lock.withLock {
            var output = Data(capacity: count)
            for _ in 0..<count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                output.append(UInt8(truncatingIfNeeded: state >> 56))
            }
            return output
        }
    }
}
