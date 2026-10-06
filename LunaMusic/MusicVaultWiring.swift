import UIKit
import LunaMusicCore
import LunaMusicUI
import LunaVaultStore
import LunaVaultUI
import LunaVaultTailscale

@MainActor enum MusicVaultWiring {
    private static var runtime: VaultConnectedRuntime?
    private static var refreshTask: Task<Void, Never>?
    static func install() {
        do {
            let store = try VaultFolderStore.production()
            let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: store.identityDirectory, requestLocalNetworkAccess: true))
            let connection = try VaultConnectedRuntime(store: store, dialer: transport, lookup: transport, localID: transport.identity())
            runtime = connection
            try VaultMusicController.shared.configure(peer: { (try? store.peer()?.deviceID.description) ?? "" }, request: { data in
                try await connection.musicRequest(data)
            })
            MusicSettings.connectionController = {
                let settings = VaultConnectedSettingsViewController(services: connection) { code in
                    try await connection.pair(code: code)
                    await VaultMusicController.shared.refresh()
                }
                settings.title = "Luna Mac"
                return settings
            }
        } catch { MusicSettings.connectionError = error.localizedDescription }
    }
    static func foreground() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while !Task.isCancelled {
                await VaultMusicController.shared.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
    }
    static func background() {
        refreshTask?.cancel(); refreshTask = nil
        // Keep the paired transport alive for background audio/range requests.
    }
}
