//
//  ArticleSpotlightIndexWiring.swift
//  Luna
//

import CoreSpotlight
import LunaIntents
import LunaModels
import LunaStorage
import Foundation

/// Keeps `ArticleEntity`'s Spotlight index in sync with the saves list:
/// installed once at launch by `ArticleShellWiring.appDidLaunch()`, it sweeps
/// on every debounced `.savesChanged` (the launch sweep waits the same
/// debounce a burst would — `SavesSweepDriver`, shared with
/// `AudioScriptPipeline` and `URLRescueCoordinator`), indexing every readable
/// article and deleting Spotlight entries for ones that are no longer
/// readable/present. Which ids the last sweep indexed is the `spotlight_index`
/// table — it has to survive a save's deletion to know the entry needs removing,
/// which is why it is a table of its own rather than a column on the save.
///
/// An article app's main process only. The Share/Action extensions never call
/// `install()` (they don't index at all; their saves get picked up the next
/// time the main app sweeps), and the Downloader / Price Tracker exclude this
/// file by membership exception — they can open no article, so a Spotlight hit
/// there would lead nowhere.
enum ArticleSpotlightIndexWiring {
    private static let domainIdentifier = "articles"

    /// The driver holds its sweeper weakly, so this indexer's stands-in object
    /// is a `static let` of its own rather than a temporary. Both live for the
    /// process, matching the enum they belong to.
    private static let sweeper = SpotlightIndexSweeper()
    private static let sweepDriver = SavesSweepDriver(
        queueLabel: "com.hsanabria.luna.articleSpotlightIndex",
        sweeper: ArticleSpotlightIndexWiring.sweeper)

    static func install() {
        sweepDriver.install(immediateLaunchSweep: false)
    }

    fileprivate static func runSweep() {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let entities = indexableEntities(from: SavesStore.shared.items())

        let searchableItems: [CSSearchableItem] = entities.map { entity in
            let item = CSSearchableItem(
                uniqueIdentifier: entity.id.uuidString,
                domainIdentifier: domainIdentifier,
                attributeSet: entity.attributeSet)
            item.associateAppEntity(entity)
            return item
        }

        let currentIDs = Set(entities.map { $0.id.uuidString })
        let previousIDs = SavesStore.shared.spotlightIndexedIDs()
        let removedIDs = removedIdentifiers(previousIDs: previousIDs, currentIDs: currentIDs)

        if !searchableItems.isEmpty {
            CSSearchableIndex.default().indexSearchableItems(searchableItems, completionHandler: nil)
        }
        if !removedIDs.isEmpty {
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: removedIDs, completionHandler: nil)
        }
        SavesStore.shared.setSpotlightIndexedIDs(currentIDs)
    }

    // MARK: - Pure (ArticleSpotlightIndexWiringTests)

    /// Which saved items this sweep indexes, in Spotlight-entity form:
    /// readable articles only — never videos, social posts, or price trackers
    /// (`ArticleReadability.isReadableArticle`).
    static func indexableEntities(from items: [SavedItem]) -> [ArticleEntity] {
        items.filter(ArticleReadability.isReadableArticle).map(ArticleEntity.init(item:))
    }

    /// Previously-indexed identifiers no longer among the current ones — what
    /// this sweep deletes from the Spotlight index.
    static func removedIdentifiers(previousIDs: Set<String>, currentIDs: Set<String>) -> [String] {
        Array(previousIDs.subtracting(currentIDs))
    }
}

/// Carries `ArticleSpotlightIndexWiring`'s sweep to the driver — the indexer is
/// an enum of statics, so the delegate is this one small object. It tracks no
/// foreground state on purpose: the index is rebuilt regardless of app state.
private final class SpotlightIndexSweeper: SavesSweeping {
    func runSavesSweep() { ArticleSpotlightIndexWiring.runSweep() }
}
