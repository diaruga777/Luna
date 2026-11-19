import Foundation
import Network
import LunaVaultBEP
import LunaVaultStore

public enum VaultAddressResolutionError: Error, Equatable, Sendable {
    case noAddresses
}

/// Resolves and orders addresses for the single paired Mac. Manual addresses
/// always lead; discovery results are cached for ten minutes, or for a
/// server-provided Retry-After after a negative lookup.
public actor VaultAddressResolver {
    private struct CacheEntry: Sendable {
        var addresses: [VaultPeerAddress]
        var expiresAt: Date
    }

    private let lookup: (any VaultPeerLookup)?
    private let isOnCellular: @Sendable () async -> Bool
    private let cacheLifetime: TimeInterval
    private let clock: @Sendable () -> Date
    private var cache: [DeviceID: CacheEntry] = [:]

    public init(lookup: (any VaultPeerLookup)?, cacheLifetime: TimeInterval = 600,
                clock: @escaping @Sendable () -> Date = { Date() },
                isOnCellular: @escaping @Sendable () async -> Bool = {
                    let monitor = NWPathMonitor()
                    defer { monitor.cancel() }
                    for await path in monitor {
                        return path.status == .satisfied && path.usesInterfaceType(.cellular)
                    }
                    return false
                }) {
        self.isOnCellular = isOnCellular
        self.lookup = lookup
        self.cacheLifetime = max(0, cacheLifetime)
        self.clock = clock
    }

    public func invalidate(_ device: DeviceID? = nil) {
        if let device { cache.removeValue(forKey: device) }
        else { cache.removeAll() }
    }

    public func addresses(for peer: VaultPeerRecord, forceRefresh: Bool = false) async throws -> [VaultPeerAddress] {
        let cellular = await isOnCellular()
        func ordered(_ addresses: [VaultPeerAddress]) -> [VaultPeerAddress] {
            Self.unique(addresses.map(\.classifyingTailscaleIP))
                .sorted { $0.dialPriority(onCellular: cellular) < $1.dialPriority(onCellular: cellular) }
        }
        var routes = ordered(peer.manualAddresses)
        if !cellular, peer.networkMode == .syncthingPublic, peer.lastConnectedAt != nil,
           let nearby = lookup as? any VaultNearbyPeerLookup,
           let address = await nearby.nearbyAddress(for: peer.deviceID) {
            routes = Self.unique([address] + routes)
        }
        if !routes.isEmpty { return routes }
        guard peer.networkMode == .syncthingPublic else { throw VaultAddressResolutionError.noAddresses }

        let now = clock()
        if !forceRefresh, let cached = cache[peer.deviceID], cached.expiresAt > now {
            guard !cached.addresses.isEmpty else { throw VaultAddressResolutionError.noAddresses }
            return ordered(cached.addresses)
        }

        guard let lookup else { throw VaultAddressResolutionError.noAddresses }
        do {
            let discovered = try await lookup.lookup(peer.deviceID).addresses
            cache[peer.deviceID] = CacheEntry(addresses: discovered, expiresAt: now.addingTimeInterval(cacheLifetime))
            guard !discovered.isEmpty else { throw VaultAddressResolutionError.noAddresses }
            return ordered(discovered)
        } catch let error as VaultTransportError {
            let retryAfter: TimeInterval?
            switch error {
            case .notFound(let delay), .lookupFailed(_, let delay): retryAfter = delay
            default: retryAfter = nil
            }
            if let retryAfter {
                cache[peer.deviceID] = CacheEntry(addresses: [], expiresAt: now.addingTimeInterval(max(0, retryAfter)))
            }
            throw error
        }
    }

    private static func unique(_ addresses: [VaultPeerAddress]) -> [VaultPeerAddress] {
        var seen = Set<VaultPeerAddress>()
        return addresses.filter { seen.insert($0).inserted }
    }
}

