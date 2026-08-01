//
//  BundledLunaArticle.swift
//  Luna
//

import LunaModels
import LunaStorage
import Foundation

/// The article the onboarding mocks show.
///
/// The copy itself lives in `OnboardingLunaArticleCopy` and is rendered by the
/// replica views alone — the mock Safari page and the mock action-extension
/// sheet. **It is never saved.** Onboarding writes nothing to the reading list,
/// so the deck the user lands on holds exactly what they saved themselves.
///
/// What remains here is the one-time sweep of the item an OLDER build did
/// install; see `OnboardingLegacyDemoSave`.
enum BundledLunaArticle {
    static let urlString = "https://luna.app"

    /// Deletes the demonstration item a previous build recorded, and clears the
    /// marker either way. Ownership is by exact id, so a save the user made
    /// themselves is never touched.
    static func cleanupLegacyTemporarySave(
        registry: AppOnboardingStore = .shared,
        in store: ReadingListStore = .shared
    ) {
        defer { registry.clearTemporarySaveIdentifier() }
        guard let identifier = registry.temporarySaveIdentifier,
              let item = store.item(withID: identifier)
        else { return }
        store.delete(item)
    }
}
