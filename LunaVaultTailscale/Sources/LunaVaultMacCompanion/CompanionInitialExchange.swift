import LunaVaultBEP
import LunaVaultMacPeer

/// Complete the shared service handshake from the durable index. Disk scans
/// run afterward: a permission prompt or slow file must not strand every app
/// in "Syncing files" whenever its network connection is replaced.
enum CompanionInitialExchange {
    static func send(connection: BEPConnection, delegate: CompanionBEPDelegate,
                     index: CompanionIndex, config: BEPClusterConfig) async throws {
        try await connection.send(clusterConfig: config)
        let files = try index.all()
        delegate.startServing(connection)
        try await connection.send(index: BEPIndex(folder: "vault", files: files,
            lastSequence: files.map(\.sequence).max() ?? 0, isUpdate: false))
    }
}
