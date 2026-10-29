import Foundation
import LunaModels
import LunaStorage

/// Literal PST (UTC−8), deliberately independent of the device zone and DST.
public enum NightlyArticleAudioWindow {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 60 * 60)!
        return calendar
    }

    public static func deadline(at date: Date) -> Date? {
        let start = calendar.startOfDay(for: date)
        let end = start.addingTimeInterval(24 * 60 * 60)
        return date >= end.addingTimeInterval(-60 * 60) && date < end ? end : nil
    }

    /// The current window can be used on launch; a completed/missed job chains
    /// to the next window rather than retrying against an exhausted quota.
    public static func nextStart(after date: Date, skipCurrentWindow: Bool = false) -> Date {
        let today = calendar.startOfDay(for: date).addingTimeInterval(23 * 60 * 60)
        if date < today { return today }
        if !skipCurrentWindow, deadline(at: date) != nil { return date }
        return today.addingTimeInterval(24 * 60 * 60)
    }
}

public enum NightlyArticleAudio {
    public static func run() async throws {
        let store = SavesStore.shared
        let scripts = AudioScriptStore(articlesDirectory: store.articlesDirectory)
        try await NightlyArticleAudioWorker(
            enabled: { AudioSettings.usesGeminiVoice && GeminiSpeechCredential.apiKey?.isEmpty == false },
            items: { store.items() },
            currentItem: { store.item(withID: $0) },
            content: { store.content(for: $0) },
            script: { item, content in
                // No foreground FoundationModels work is started by a BG task.
                if let name = item.contentFileName, let cached = scripts.load(forContentFileName: name) {
                    return cached.script
                }
                let script = AudioTrimHeuristics.classify(content).heuristicScript(for: content)
                if let name = item.contentFileName {
                    scripts.save(.init(script: script, refinementState: .heuristicOnly), forContentFileName: name)
                }
                return script
            },
            prepare: { item, script, author, deadline in
                try await GeminiArticleSpeech.shared.cacheForNightlyReadout(itemID: item.id, script: script, author: author, deadline: deadline)
            }).run()
    }
}

/// Dependency seams keep clock boundaries, changing read state and early exit
/// testable without background launches or spending a real Gemini allowance.
struct NightlyArticleAudioWorker {
    var now: () -> Date = Date.init
    let enabled: () -> Bool
    let items: () -> [SavedItem]
    let currentItem: (UUID) -> SavedItem?
    let content: (SavedItem) -> ArticleContent?
    let script: (SavedItem, ArticleContent) -> AudioScript
    let prepare: (SavedItem, AudioScript, String?, Date) async throws -> Void

    func run() async throws {
        let started = now()
        guard let deadline = NightlyArticleAudioWindow.deadline(at: started), enabled() else { return }
        // Saved order can be manually rearranged; recency here means save time.
        let candidates = items().filter { Self.isEligible($0, at: started) }
            .sorted { $0.dateAdded == $1.dateAdded ? $0.id.uuidString < $1.id.uuidString : $0.dateAdded > $1.dateAdded }
        for candidate in candidates {
            try Task.checkCancellation()
            guard now() < deadline, enabled() else { return }
            guard let item = currentItem(candidate.id), Self.isEligible(item, at: now()),
                  let content = content(item), AudioScriptPipeline.isReadable(content) else { continue }
            let script = script(item, content)
            guard !script.spokenBlocks.isEmpty else { continue }
            guard now() < deadline, enabled() else { return }
            // Loading content/building the script may overlap a read-state change
            // or cross the age cutoff. Recheck immediately before preparation.
            guard let current = currentItem(item.id), Self.isEligible(current, at: now()) else { continue }
            // Cache hits are network-free. Missing chunks resume sequentially.
            // Any error, especially quota, exits the entire job immediately.
            try await prepare(current, script, content.author, deadline)
        }
    }

    private static func isEligible(_ item: SavedItem, at date: Date) -> Bool {
        item.state == .ready && item.exportKind == .article && item.readState != .read
            && !item.isArchived && item.pendingArchiveAt == nil
            && date.timeIntervalSince(item.dateAdded) < 14 * 24 * 60 * 60
    }
}
