//
//  DownloaderOnboardingDemoSave.swift
//  Luna
//

import LunaMediaDownload
import LunaModels
import LunaStorage
import Foundation

/// The video the Downloader's onboarding mocks show is rendered by the
/// replica views alone and is never saved. This file only sweeps the demo
/// item a previous app version installed — see `OnboardingLegacyDemoSave`.
enum DownloaderOnboardingDemoSave {
    static let legacyCleanup: any OnboardingLegacyDemoSweeping = LegacySweep()

    private struct LegacySweep: OnboardingLegacyDemoSweeping {
        func sweepLegacyDemoSave() { DownloaderOnboardingDemoSave.cleanup() }
    }

    /// Deletes the demonstration item a previous build recorded, and clears the
    /// marker either way. Ownership is by exact id, so a save the user made
    /// themselves is never touched.
    fileprivate static func cleanup() {
        let registry = AppOnboardingStore.shared
        defer { registry.clearTemporarySaveIdentifier() }
        guard let identifier = registry.temporarySaveIdentifier,
              let item = SavedMediaStore.shared.items().first(where: {
                  $0.id == identifier
              })
        else { return }
        SavedMediaStore.shared.delete(item)
    }
}
