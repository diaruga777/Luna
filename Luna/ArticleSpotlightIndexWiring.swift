//
//  ArticleSpotlightIndexWiring.swift
//  Luna
//

import CoreSpotlight
import LunaIntents
import LunaStorage
import Foundation

/// Keeps `ArticleEntity`'s Spotlight index in sync with the reading list:
/// installed once at launch (`AppDelegate`, right after `AudioPlaybackWiring`/
/// `AudioScriptPipelineWiring`), it sweeps immediately and again on every
/// debounced `.readingListChanged` (mirrors `AudioScriptPipeline`'s
/// debounce), indexing every readable article and deleting Spotlight entries
/// for ones that are no longer readable/present. Main-app-only — the
/// Share/Action extensions never call `install()` (they don't index at all;
/// their saves get picked up the next time the main app sweeps).
enum ArticleSpotlightIndexWiring {
    private static let domainIdentifier = "articles"
    private static let lastIndexedIDsKey = "articleSpotlightIndex.lastIndexedIDs"
    private static let debounceInterval: TimeInterval = 1.5
    private static let workQueue = DispatchQueue(label: "com.hsanabria.luna.articleSpotlightIndex", qos: .utility)

    private static var notificationObserver: NSObjectProtocol?
    private static var debounceWorkItem: DispatchWorkItem?

    static func install() {
        guard notificationObserver == nil else { return }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .readingListChanged, object: nil, queue: .main
        ) { _ in scheduleSweep() }
        scheduleSweep() // launch sweep
    }

    private static func scheduleSweep() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { runSweep() }
        debounceWorkItem = work
        workQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private static func runSweep() {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let entities = ReadingListStore.shared.items()
            .filter(ArticleReadability.isReadableArticle)
            .map(ArticleEntity.init(item:))

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
        let removedIDs = Array(previousIDs.subtracting(currentIDs))

        if !searchableItems.isEmpty {
            CSSearchableIndex.default().indexSearchableItems(searchableItems, completionHandler: nil)
        }
        if !removedIDs.isEmpty {
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: removedIDs, completionHandler: nil)
        }
        defaults.set(Array(currentIDs), forKey: lastIndexedIDsKey)
    }
}
