import Foundation
import UIKit
import LunaVaultUI

/// The composition seam for Luna Vault. Provider, crypto, indexing and sync
/// services are intentionally absent in Stage 1; later stages install them
/// behind this boundary without making SceneDelegate a service locator.
enum VaultWiring {
    private static let services: VaultRuntimeServices? = {
        try? VaultRuntimeServices.productionFromDefaults()
    }()
    private static let syncRuntime = services.flatMap { VaultSyncRuntimeController(services: $0) }

    static func install() { _ = syncRuntime }

    static func applicationDidEnterBackground() {
        syncRuntime?.applicationDidEnterBackground()
    }

    static func applicationWillEnterForeground() {
        syncRuntime?.applicationWillEnterForeground()
    }

    static func makeRootViewController() -> UIViewController {
        VaultRootViewController(services: services)
    }
}
