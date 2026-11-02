import LunaCompanionSharing
import LunaVaultTailscale
import LunaVaultStore

final class ShareViewController: MusicAudioShareViewController {
    override func viewDidLoad() {
        resolveYouTube = { input in
            let store = try VaultFolderStore.production()
            let runtime = try LunaMacConnection.makeRuntime(client: .music, store: store)
            do {
                let result = try await MusicYouTubeShare.resolve(input) { try await runtime.musicRequest($0) }
                await runtime.stop()
                return result
            } catch {
                await runtime.stop()
                throw error
            }
        }
        super.viewDidLoad()
    }
}
