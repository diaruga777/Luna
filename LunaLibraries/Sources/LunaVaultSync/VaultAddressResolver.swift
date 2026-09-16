import Foundation
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
    private let cacheLifetime: TimeInterval
    private let clock: @Sendable () -> Date
    private var cache: [DeviceID: CacheEntry] = [:]

    public init(lookup: (any VaultPeerLookup)?, cacheLifetime: TimeInterval = 600,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.lookup = lookup
        self.cacheLifetime = max(0, cacheLifetime)
        self.clock = clock
    }

    public func invalidate(_ device: DeviceID? = nil) {
        if let device { cache.removeValue(forKey: device) }
        else { cache.removeAll() }
    }

    public func addresses(for peer: VaultPeerRecord, forceRefresh: Bool = false) async throws -> [VaultPeerAddress] {
        var result = Self.unique(peer.manualAddresses)
        guard peer.networkMode == .syncthingPublic, result.isEmpty else {
            guard !result.isEmpty else { throw VaultAddressResolutionError.noAddresses }
            return result
        }

        let now = clock()
        if !forceRefresh, let cached = cache[peer.deviceID], cached.expiresAt > now {
            result.append(contentsOf: cached.addresses)
            result = Self.unique(result)
            guard !result.isEmpty else { throw VaultAddressResolutionError.noAddresses }
            return result
        }

        guard let lookup else {
            guard !result.isEmpty else { throw VaultAddressResolutionError.noAddresses }
            return result
        }
        do {
            let discovered = try await lookup.lookup(peer.deviceID).addresses
                .sorted { lhs, rhs in lhs.dialPriority < rhs.dialPriority }
            cache[peer.deviceID] = CacheEntry(addresses: discovered, expiresAt: now.addingTimeInterval(cacheLifetime))
            result.append(contentsOf: discovered)
        } catch let error as VaultTransportError {
            let retryAfter: TimeInterval?
            switch error {
            case .notFound(let delay), .lookupFailed(_, let delay): retryAfter = delay
            default: retryAfter = nil
            }
            if let retryAfter {
                cache[peer.deviceID] = CacheEntry(addresses: [], expiresAt: now.addingTimeInterval(max(0, retryAfter)))
            }
            if result.isEmpty { throw error }
        }
        result = Self.unique(result)
        guard !result.isEmpty else { throw VaultAddressResolutionError.noAddresses }
        return result
    }

    private static func unique(_ addresses: [VaultPeerAddress]) -> [VaultPeerAddress] {
        var seen = Set<VaultPeerAddress>()
        return addresses.filter { seen.insert($0).inserted }
    }
}

