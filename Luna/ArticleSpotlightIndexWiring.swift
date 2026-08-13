//
//  ArticleSpotlightIndexWiring.swift
//  Luna
//

import CoreSpotlight
import LunaIntents
import LunaModels
import LunaStorage
import Foundation

/// Keeps `ArticleEntity`'s Spotlight index in sync with the reading list:
/// installed once at launch by `ArticleShellWiring.appDidLaunch()`, it sweeps
/// on every debounced `.readingListChanged` (the launch sweep waits the same
/// debounce a burst would — `ReadingListSweepDriver`, shared with
/// `AudioScriptPipeline` and `URLRescueCoordinator`), indexing every readable
/// article and deleting Spotlight entries for ones that are no longer
/// readable/present.
///
/// An article app's main process only. The Share/Action extensions never call
/// `install()` (they don't index at all; their saves get picked up the next
/// time the main app sweeps), and the Downloader / Price Tracker exclude this
/// file by membership exception — they can open no article, so a Spotlight hit
/// there would lead nowhere.
enum ArticleSpotlightIndexWiring {
    private static let domainIdentifier = "articles"
    private static let lastIndexedIDsKey = "articleSpotlightIndex.lastIndexedIDs"

    private static let sweepDriver = ReadingListSweepDriver(
        queueLabel: "com.hsanabria.luna.articleSpotlightIndex",
        runSweep: { runSweep() })

    static func install() {
        sweepDriver.install(immediateLaunchSweep: false)
    }

    private static func runSweep() {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let entities = indexableEntities(from: ReadingListStore.shared.items())

        let searchableItems: [CSSearchableItem] = entities.map { entity in
            let item = CSSearchableItem(
                uniqueIdentifier: entity.id.uuidString,
                domainIdentifier: domainIdentifier,
                attributeSet: entity.attributeSet)
            item.associateAppEntity(entity)
            return item
        }

        let defaults = UserDefaults(suiteName: ReadingListStore.appGroupID) ?? .standard
        let currentIDs = Set(entities.map { $0.id.uuidString })
        let previousIDs = Set(defaults.stringArray(forKey: lastIndexedIDsKey) ?? [])
        let removedIDs = removedIdentifiers(previousIDs: previousIDs, currentIDs: currentIDs)

        if !searchableItems.isEmpty {
            CSSearchableIndex.default().indexSearchableItems(searchableItems, completionHandler: nil)
        }
        if !removedIDs.isEmpty {
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: removedIDs, completionHandler: nil)
        }
        defaults.set(Array(currentIDs), forKey: lastIndexedIDsKey)
    }

    // MARK: - Pure (ArticleSpotlightIndexWiringTests)

    /// Which reading-list items this sweep indexes, in Spotlight-entity form:
    /// readable articles only — never videos, social posts, or price trackers
    /// (`ArticleReadability.isReadableArticle`).
    static func indexableEntities(from items: [ReadingListItem]) -> [ArticleEntity] {
        items.filter(ArticleReadability.isReadableArticle).map(ArticleEntity.init(item:))
    }

    /// Previously-indexed identifiers no longer among the current ones — what
    /// this sweep deletes from the Spotlight index.
    static func removedIdentifiers(previousIDs: Set<String>, currentIDs: Set<String>) -> [String] {
        Array(previousIDs.subtracting(currentIDs))
    }
}
