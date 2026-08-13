//
//  PriceTrackerOnboardingDemoSave.swift
//  Luna
//

import Foundation
import LunaModels
import LunaStorage

/// The tracked product the Price Tracker's onboarding mocks show is rendered
/// by the replica views alone and is never saved. This file only sweeps the
/// demo item a previous app version installed, including its product image —
/// see `OnboardingLegacyDemoSave`.
enum PriceTrackerOnboardingDemoSave {
    static let legacyCleanup: any OnboardingLegacyDemoSweeping = LegacySweep()

    private struct LegacySweep: OnboardingLegacyDemoSweeping {
        func sweepLegacyDemoSave() { PriceTrackerOnboardingDemoSave.cleanup() }
    }

    /// Deletes the demonstration item a previous build recorded, and clears the
    /// marker either way. Ownership is by exact id, so a save the user made
    /// themselves is never touched.
    fileprivate static func cleanup() {
        let registry = AppOnboardingStore.shared
        defer { registry.clearTemporarySaveIdentifier() }
        guard let identifier = registry.temporarySaveIdentifier,
              let item = SavesStore.shared.item(withID: identifier)
        else { return }
        if let imageFileName = item.priceTracker?.imageFileName {
            try? FileManager.default.removeItem(
                at: SavesStore.shared.articlesDirectory
                    .appendingPathComponent(imageFileName))
        }
        SavesStore.shared.delete(item)
    }
}
