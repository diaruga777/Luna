import Foundation
import LunaVaultBEP

/// Multiple sockets and physical devices may use one synchronized identity.
/// A different identity requires an explicit reset on the Mac. The generation
/// prevents an approval dialog opened before a reset from reauthorizing it.
public final class CompanionAccountGate: @unchecked Sendable {
    private let lock = NSLock()
    private var device: DeviceID?
    private var epoch = 0
    public init(trustedDevice: DeviceID? = nil) { device = trustedDevice }
    public var trustedDevice: DeviceID? { lock.lock(); defer { lock.unlock() }; return device }
    public var generation: Int { lock.lock(); defer { lock.unlock() }; return epoch }
    public func allows(_ candidate: DeviceID, pairingOpen: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return device.map { $0 == candidate } ?? pairingOpen
    }
    @discardableResult public func approve(_ candidate: DeviceID, generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == epoch, device == nil || device == candidate else { return false }
        device = candidate
        return true
    }
    public func reset() { lock.lock(); defer { lock.unlock() }; epoch += 1; device = nil }
}
