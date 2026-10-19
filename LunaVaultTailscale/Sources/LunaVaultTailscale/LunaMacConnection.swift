#if os(iOS)
import Foundation
import Network
import Darwin
import LunaAppConfig
import LunaVaultBEP
import LunaVaultStore
import LunaVaultUI

/// The sole production composition point for Vault, Music, and Code.
public enum LunaMacConnection {
    public static func makeRuntime(client: LunaMacClient, store: VaultFolderStore,
                                   credentials: (any LunaMacCredentialStoring)? = nil) throws -> VaultConnectedRuntime {
        let credentials: any LunaMacCredentialStoring = try credentials ?? {
            guard let group = AppConfig.macConnectionKeychainAccessGroup else { throw LunaMacCredentialError.missingAccessGroup }
            return LunaMacKeychain(accessGroup: group)
        }()
        let identity = LunaMacIdentityStore(root: store.rootURL, credentials: credentials)
        // Preserve previously approved local pairings when upgrading.
        if try identity.restore() == nil, let peer = try store.peer(), peer.lastConnectedAt != nil {
            let local = LunaVaultGoTransport(configuration: .init(stateDirectory: store.identityDirectory, requestLocalNetworkAccess: true))
            try identity.publish(peer: peer, identityDirectory: store.identityDirectory, expectedID: local.identity())
        }
        let initial = try identity.restore()
        let transport = initial?.1 ?? LunaVaultGoTransport(configuration: .init(stateDirectory: store.identityDirectory, requestLocalNetworkAccess: true))
        let localID = try transport.identity()
        return try VaultConnectedRuntime(store: store, dialer: transport, lookup: transport, localID: localID, client: client,
            restoreShared: {
                guard let (value, restored) = try identity.restore() else { return nil }
                return VaultSharedConnection(revision: value.revision, localID: try restored.identity(),
                    dialer: restored, lookup: restored, peer: try value.pairing?.peer())
            }, persistShared: { peer, expectedID in
                let restored = try identity.restore()
                let directory: URL
                let id: DeviceID
                if let (value, restored) = restored {
                    directory = store.rootURL.appendingPathComponent("SharedIdentities/" + value.identityFingerprint)
                    id = try restored.identity()
                    guard id == expectedID else { throw LunaMacCredentialError.changedIdentity }
                } else { directory = store.identityDirectory; id = expectedID }
                try identity.publish(peer: peer, identityDirectory: directory, expectedID: id)
            })
    }
}

/// A separate session keeps scheduled Code work from changing the foreground
/// Vault connection. No discovery, relay or tailnet is available on this path.
extension LunaMacConnection {
    public static func makeOvernightCodeRuntime() async throws -> (runtime: VaultConnectedRuntime, peerID: String) {
        guard let group = AppConfig.macConnectionKeychainAccessGroup else { throw LunaMacCredentialError.missingAccessGroup }
        let shared = try VaultFolderStore.production()
        let identity = LunaMacIdentityStore(root: shared.rootURL, credentials: LunaMacKeychain(accessGroup: group))
        guard let (credentials, transport) = try identity.restore(), var peer = try credentials.pairing?.peer() else {
            throw VaultTransportError.internalError("Connect Luna Code to your Mac first.")
        }
        let interfaces = try await LocalCodeWiFi.interfaces()
        peer.manualAddresses = peer.manualAddresses.filter { LocalCodeWiFi.isLocal($0, interfaces: interfaces) }
        guard !peer.manualAddresses.isEmpty else { throw VaultTransportError.unreachable("Your Mac isn’t on this local Wi-Fi network.") }
        let store = try VaultFolderStore(rootURL: shared.rootURL.deletingLastPathComponent().appendingPathComponent("Code/OvernightConnection"))
        try store.savePeer(peer)
        return (try VaultConnectedRuntime(store: store, dialer: LocalCodeWiFiDialer(transport: transport),
            lookup: nil, localID: transport.identity(), client: .code), peer.deviceID.description)
    }
    public static func overnightCodeRequest(_ payload: Data, runtime: VaultConnectedRuntime) async throws -> Data {
        // Recheck on every RPC, including an already-open connection.
        let interfaces = try await LocalCodeWiFi.interfaces()
        guard let peer = try runtime.store.peer(), peer.manualAddresses.contains(where: { LocalCodeWiFi.isLocal($0, interfaces: interfaces) }) else {
            throw VaultTransportError.unreachable("Your Mac isn’t on this local Wi-Fi network.")
        }
        return try await runtime.codeRequest(payload)
    }
}

private struct LocalCodeWiFiDialer: VaultPeerDialing {
    let transport: LunaVaultGoTransport
    func dial(_ address: VaultPeerAddress, expecting expected: DeviceID) async throws -> any BEPByteStream {
        let interfaces = try await LocalCodeWiFi.interfaces()
        guard LocalCodeWiFi.isLocal(address, interfaces: interfaces) else { throw VaultTransportError.unreachable("A local Wi-Fi connection is required.") }
        return try await transport.dial(address, expecting: expected)
    }
}
private enum LocalCodeWiFi {
    static func interfaces() async throws -> Set<String> {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            // Both completion paths run on one serial queue.
            let queue = DispatchQueue(label: "Luna.Code.WiFi")
            let completion = LocalCodeWiFiCompletion()
            monitor.pathUpdateHandler = { path in
                guard completion.claim() else { return }; monitor.pathUpdateHandler = nil; monitor.cancel()
                let names = Set(path.availableInterfaces.filter { $0.type == .wifi }.map(\.name))
                if path.status == .satisfied, path.usesInterfaceType(.wifi), !names.isEmpty { continuation.resume(returning: names) }
                else { continuation.resume(throwing: VaultTransportError.unreachable("Connect to your Mac’s local Wi-Fi first.")) }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) {
                guard completion.claim() else { return }; monitor.pathUpdateHandler = nil; monitor.cancel()
                continuation.resume(throwing: VaultTransportError.unreachable("Wi-Fi is unavailable."))
            }
        }
    }
    static func isLocal(_ address: VaultPeerAddress, interfaces: Set<String>) -> Bool {
        // Fail closed for hostnames, relays, routed networks and VPN addresses.
        // Pairing codes include the Mac's numeric LAN addresses. IPv4 covers
        // conventional home LANs; unsupported configurations simply skip a night.
        guard case .tcp(let host, _) = address else { return false }
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1 else { return false }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        var current = list
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard interfaces.contains(String(cString: entry.pointee.ifa_name)),
                  let local = entry.pointee.ifa_addr, local.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let ip = UnsafeRawPointer(local).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            let bits = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            if bits != 0, target.s_addr != ip, target.s_addr & bits == ip & bits { return true }
        }
        return false
    }
}

private final class LocalCodeWiFiCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true; return true
    }
}

#endif
