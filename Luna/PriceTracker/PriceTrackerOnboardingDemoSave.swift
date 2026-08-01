//
//  PriceTrackerOnboardingDemoSave.swift
//  Luna
//

import Foundation
import LunaModels
import LunaStorage

/// The tracked product the Price Tracker's onboarding mocks show is rendered by
/// the replica views alone and is **never saved**. What remains here is the
/// one-time sweep of the item an OLDER build installed (its product image
/// included) — see `OnboardingLegacyDemoSave`.
enum PriceTrackerOnboardingDemoSave {
    static let legacyCleanup = OnboardingLegacyDemoSave(cleanup: cleanup)

    /// Deletes the demonstration item a previous build recorded, and clears the
    /// marker either way. Ownership is by exact id, so a save the user made
    /// themselves is never touched.
    private static func cleanup() {
        let registry = AppOnboardingStore.shared
        defer { registry.clearTemporarySaveIdentifier() }
        guard let identifier = registry.temporarySaveIdentifier,
              let item = ReadingListStore.shared.item(withID: identifier)
        else { return }
        if let imageFileName = item.priceTracker?.imageFileName {
            try? FileManager.default.removeItem(
                at: ReadingListStore.shared.articlesDirectory
                    .appendingPathComponent(imageFileName))
        }
        ReadingListStore.shared.delete(item)
    }
}
