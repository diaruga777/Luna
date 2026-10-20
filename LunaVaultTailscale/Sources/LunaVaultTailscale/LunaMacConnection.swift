#if os(iOS)
import Foundation
import LunaCodeCore
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
/// Vault connection. Only explicit Code provider addresses are considered;
/// this path never uses public discovery, embedded tsnet or global Vault policy.
extension LunaMacConnection {
    public static func makeOvernightCodeRuntime(policy: CodeOvernightPolicy = CodeOvernightPolicy(), record: @escaping @Sendable (CodeInstallProvider, String) -> Void = { _, _ in }) async throws -> (runtime: VaultConnectedRuntime, peerID: String) {
        guard let group = AppConfig.macConnectionKeychainAccessGroup else { throw LunaMacCredentialError.missingAccessGroup }
        let shared = try VaultFolderStore.production()
        let identity = LunaMacIdentityStore(root: shared.rootURL, credentials: LunaMacKeychain(accessGroup: group))
        guard let (credentials, transport) = try identity.restore(), var peer = try credentials.pairing?.peer() else {
            throw VaultTransportError.internalError("Connect Luna Code to your Mac first.")
        }
        let interfaces = try await LocalCodeWiFi.interfaces()
        var seenAddresses = Set<VaultPeerAddress>()
        var addresses = Array(peer.manualAddresses.filter { LocalCodeWiFi.isLocal($0, interfaces: interfaces) && seenAddresses.insert($0).inserted }.prefix(2))
        var providers = Dictionary(uniqueKeysWithValues: addresses.map { ($0, CodeInstallProvider.local) })
        var seen = Set<CodeInstallProvider>()
        for provider in policy.remoteProviders where seen.insert(provider).inserted {
            if provider == .tailscale, let text = policy.tailscaleAddress,
               let address = VaultPeerAddress(syncthingURL: text), case .tcp = address {
                if providers[address] == nil { addresses.append(address); providers[address] = provider }
            }
            if provider == .syncthing, let text = policy.relayAddress,
               let address = VaultPeerAddress(syncthingURL: text), case .relay = address {
                if providers[address] == nil { addresses.append(address); providers[address] = provider }
            }
        }
        guard !addresses.isEmpty else { throw VaultTransportError.unreachable("Your Mac isn’t on this Wi-Fi network. Configure a remote connection in Overnight Builds.") }
        peer.manualAddresses = addresses
        peer.networkMode = .tailscale // Legacy explicit-address mode; no embedded tailnet is started.
        let store = try VaultFolderStore(rootURL: shared.rootURL.deletingLastPathComponent().appendingPathComponent("Code/OvernightConnection"))
        try store.savePeer(peer)
        return (try VaultConnectedRuntime(store: store, dialer: CodeWiFiProviderDialer(transport: transport, providers: providers, record: record),
            lookup: nil, localID: transport.identity(), client: .code), peer.deviceID.description)
    }
    public static func overnightCodeRequest(_ payload: Data, runtime: VaultConnectedRuntime) async throws -> Data {
        // Recheck on every RPC, including an already-open connection.
        _ = try await LocalCodeWiFi.interfaces()
        return try await runtime.codeRequest(payload)
    }
}

private actor CodeWiFiProviderDialer: VaultPeerDialing {
    let transport: LunaVaultGoTransport
    let providers: [VaultPeerAddress: CodeInstallProvider]
    let record: @Sendable (CodeInstallProvider, String) -> Void
    private var authenticationFailed = false
    init(transport: LunaVaultGoTransport, providers: [VaultPeerAddress: CodeInstallProvider], record: @escaping @Sendable (CodeInstallProvider, String) -> Void) {
        self.transport = transport; self.providers = providers; self.record = record
    }
    func dial(_ address: VaultPeerAddress, expecting expected: DeviceID) async throws -> any BEPByteStream {
        _ = try await LocalCodeWiFi.interfaces()
        guard !authenticationFailed, let provider = providers[address] else { throw CodeFailure("The Mac’s identity changed. Review the connection before trying another route.") }
        record(provider, "dialing")
        do {
            let stream = try await transport.dial(address, expecting: expected)
            if Task.isCancelled { stream.close(); throw CancellationError() }
            record(provider, "authenticated"); return stream
        } catch {
            if let error = error as? VaultTransportError {
                switch error {
                case .identityMismatch, .handshakeFailed: authenticationFailed = true
                default: break
                }
            }
            record(provider, authenticationFailed ? "authenticationFailed" : "unreachable")
            throw error
        }
    }
}
private enum LocalCodeWiFi {
    static func interfaces() async throws -> Set<String> {
        try Task.checkCancellation()
        let completion = LocalCodeWiFiCompletion()
        return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            // Both completion paths run on one serial queue.
            let queue = DispatchQueue(label: "Luna.Code.WiFi")
            completion.install {
                guard completion.claim() else { return }; monitor.pathUpdateHandler = nil; monitor.cancel()
                continuation.resume(throwing: CancellationError())
            }
            monitor.pathUpdateHandler = { path in
                guard completion.claim() else { return }; monitor.pathUpdateHandler = nil; monitor.cancel()
                let names = Set(path.availableInterfaces.filter { $0.type == .wifi }.map(\.name))
                if path.status == .satisfied, path.usesInterfaceType(.wifi), !names.isEmpty { continuation.resume(returning: names) }
                else { continuation.resume(throwing: CodeOvernightSkip(stage: "wifi", message: "Connect to Wi-Fi before requesting an overnight build.")) }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) {
                guard completion.claim() else { return }; monitor.pathUpdateHandler = nil; monitor.cancel()
                continuation.resume(throwing: CodeOvernightSkip(stage: "wifi", message: "Wi-Fi is unavailable."))
            }
        }
        } onCancel: { completion.cancel() }
    }
    private static func isLocalIPv6(_ host: String, interfaces: Set<String>) -> Bool {
        let components = host.split(separator: "%", maxSplits: 1)
        if components.count == 2, !interfaces.contains(String(components[1])) { return false }
        var target = in6_addr()
        guard let numeric = components.first, inet_pton(AF_INET6, String(numeric), &target) == 1 else { return false }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }; defer { freeifaddrs(list) }
        let targetBytes = withUnsafeBytes(of: target) { Array($0) }
        var current = list
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard interfaces.contains(String(cString: entry.pointee.ifa_name)),
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET6),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            let bits = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            let localBytes = withUnsafeBytes(of: ip) { Array($0) }, maskBytes = withUnsafeBytes(of: bits) { Array($0) }
            if maskBytes.contains(where: { $0 != 0 }), targetBytes != localBytes,
               zip(zip(targetBytes, localBytes), maskBytes).allSatisfy({ ($0.0.0 & $0.1) == ($0.0.1 & $0.1) }) { return true }
        }
        return false
    }
    static func isLocal(_ address: VaultPeerAddress, interfaces: Set<String>) -> Bool {
        // Fail closed for hostnames, relays, routed networks and VPN addresses.
        // Pairing codes include the Mac's numeric LAN addresses. IPv4 covers
        // conventional home LANs; unsupported configurations simply skip a night.
        guard case .tcp(let host, _) = address else { return false }
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1 else { return isLocalIPv6(host, interfaces: interfaces) }
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
    private var cancelled = false
    private var handler: (() -> Void)?
    func install(_ handler: @escaping () -> Void) {
        lock.lock(); let cancelled = cancelled
        if !cancelled { self.handler = handler }; lock.unlock()
        if cancelled { handler() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let handler = handler; lock.unlock(); handler?()
    }
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true; handler = nil; return true
    }
}

#endif
