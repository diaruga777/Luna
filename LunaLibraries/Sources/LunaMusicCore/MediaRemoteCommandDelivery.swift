import Foundation
import MediaPlayer

enum MediaRemoteCommandDelivery {
    nonisolated static func perform(_ action: @MainActor () -> MPRemoteCommandHandlerStatus) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread { return MainActor.assumeIsolated { action() } }
        // Finish handling the command (and acquire background execution for
        // cold preparation) before telling the system it has succeeded.
        return DispatchQueue.main.sync { MainActor.assumeIsolated { action() } }
    }
}
