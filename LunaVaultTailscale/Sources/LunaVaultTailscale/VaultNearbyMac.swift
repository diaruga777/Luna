import Foundation
import LunaVaultBEP

/// DNS-SD supplies only a routing hint. The subsequent TLS dial verifies the full certificate ID.
@MainActor public final class VaultNearbyMac: NSObject, NetServiceDelegate {
    private static let type = "_luna-vault._tcp."
    private let service: NetService
    private var result: CheckedContinuation<VaultPeerAddress?, Never>?

    private init(service: NetService) {
        self.service = service
        super.init()
        service.delegate = self
    }

    #if os(macOS)
    public static func advertise(device: DeviceID, port: UInt16) -> VaultNearbyMac {
        let service = NetService(domain: "local.", type: type, name: device.description, port: Int32(port))
        let advertisement = VaultNearbyMac(service: service)
        service.publish(options: .noAutoRename)
        return advertisement
    }
    public func stop() { service.stop() }
    #endif

    static func resolve(device: DeviceID) async -> VaultPeerAddress? {
        let lookup = VaultNearbyMac(service: NetService(domain: "local.", type: type, name: device.description))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                lookup.result = continuation
                lookup.service.resolve(withTimeout: 2)
            }
        } onCancel: { Task { @MainActor in lookup.finish(nil) } }
    }

    public nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            guard let host = service.hostName, let port = UInt16(exactly: service.port), port > 0 else {
                finish(nil)
                return
            }
            finish(.tcp(host: host, port: port))
        }
    }

    public nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in finish(nil) }
    }

    private func finish(_ address: VaultPeerAddress?) {
        service.delegate = nil
        service.stop()
        result?.resume(returning: address)
        result = nil
    }
}
