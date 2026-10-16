import Foundation
import LunaVaultBEP
import LunaVaultStore

/// Restored authentication and pairing. Index cursors, caches, and pending
/// uploads remain local to each physical device.
public struct VaultSharedConnection: Sendable {
    public let revision: String
    public let localID: DeviceID
    public let dialer: any VaultPeerDialing
    public let lookup: (any VaultPeerLookup)?
    public let peer: VaultPeerRecord?
    public init(revision: String, localID: DeviceID, dialer: any VaultPeerDialing,
                lookup: (any VaultPeerLookup)?, peer: VaultPeerRecord?) {
        self.revision = revision; self.localID = localID; self.dialer = dialer
        self.lookup = lookup; self.peer = peer
    }
}
