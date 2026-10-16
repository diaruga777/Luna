#if os(iOS)
import Foundation
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
#endif
