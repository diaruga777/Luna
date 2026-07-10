//
//  AudioPlaybackWiring.swift
//  Luna
//

import LunaAudioPlayback
import LunaReadingListUI
import LunaStorage
import LunaModels
import Foundation

/// App-shell composition for the new audio-playback stack (Phase 2 of
/// `claudedocs/audio-playback-plan.md`): installed once at launch from
/// `AppDelegate`, in all three Luna apps (the machinery is universal;
/// playback simply never starts outside Reader-surface flows until the
/// Phase 3 UI lands).
///
/// This is the injected-closure composition pattern the app shell already
/// uses (`SocialMessageCenter.ingestHandler`, `DiagnosticLog.export*`,
/// `PriceTrackingViewController.defaultSaveAsArticle`):
/// `LunaAudioPlayback` cannot know about `ReadingListSectioning`'s
/// list ordering, so the queue rule lives here where both sides are visible.
enum AudioPlaybackWiring {

    static func install() {
        AudioPlaybackCenter.shared.nextItemProvider = {
            let store = ReadingListStore.shared
            return AudioQueueRule.nextCandidate(
                items: store.items(),
                now: Date(),
                excludedItemID: AudioPlaybackCenter.shared.currentItemInfo?.itemID,
                content: { store.content(for: $0) })
        }
        NowPlayingCoordinator.shared.registerAtLaunch(center: .shared)
    }
}

/// The autoplay queue rule, as pure logic (unit-tested in
/// `AudioQueueRuleTests`): the TOP-MOST item in the Reader-surface list's own
/// displayed order whose `readState == .unopened` and which is a readable
/// article, excluding the currently playing item. Opened-but-unfinished items
/// are deliberately NOT auto-queued (product decision — see the plan doc's
/// decisions log).
enum AudioQueueRule {

    /// - Parameters:
    ///   - items: the full store list, in store order (`ReadingListStore.items()`).
    ///   - now: the sectioning clock (items older than the archive age fall
    ///     below the Reading section, exactly as displayed).
    ///   - excludedItemID: the currently playing item (normally already
    ///     `.read` by the time this runs — the exclusion is belt-and-braces).
    ///   - content: loads an item's extracted `ArticleContent` (the store's
    ///     `content(for:)`); called only for items that pass every cheaper
    ///     check first.
    static func nextCandidate(
        items: [ReadingListItem],
        now: Date,
        excludedItemID: UUID?,
        content: (ReadingListItem) -> ArticleContent?
    ) -> QueueCandidate? {
        // Reproduce EXACTLY what the Reader-surface reading list displays:
        // the surface filter, then `assignSections`, then the sections'
        // display order (for reader items only Reading, Archive, and Error
        // can be non-empty; Error items never pass the readability check).
        let surfaceItems = items.filter { AppSurface.reader.includes($0) }
        let buckets = ReadingListSectioning.assignSections(items: surfaceItems, now: now)
        let ordered = buckets.reading + buckets.archive + buckets.failed

        for item in ordered {
            guard item.readState == .unopened else { continue }
            guard item.id != excludedItemID else { continue }
            // Readable article: extraction finished (`.ready` — skips
            // pending items and paywalled `needsCaptcha` stubs) and the
            // extracted content actually has text to speak.
            guard item.state == .ready else { continue }
            guard let articleContent = content(item),
                  articleContent.blocks.contains(where: { !$0.text.isEmpty })
            else { continue }
            return QueueCandidate(item: item, content: articleContent)
        }
        return nil
    }
}
