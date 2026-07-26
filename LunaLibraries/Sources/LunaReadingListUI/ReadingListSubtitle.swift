//
//  ReadingListSubtitle.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import Foundation

/// Pure assembly of a reading-list row's grey metadata line. Produces the
/// ordered, dot-separated text parts (leading label, date, reading time,
/// progress, send status, lifecycle status) and, separately, the optional
/// "from <friend>" attribution that the view renders in the accent color.
/// Extracted from `ReadingListViewController.secondaryText` so the formatting
/// rules can be unit-tested without UIKit, `PlatformRegistry`, or defaults.
public enum ReadingListSubtitle {
    /// Human-readable destination names, keyed by destination id.
    public static let destinationNames: [String: String] = [
        ArticleDestinationID.kindle: L10n.string("Kindle"),
    ]

    /// Words read per minute used for the reading-time estimate.
    public static let wordsPerMinute = 220.0

    /// The dot-separated parts of the metadata line, in display order. The view
    /// joins these with " · " and renders them in the base (grey) color.
    ///
    /// - Parameters:
    ///   - item: the row's item.
    ///   - leadingLabel: the already-resolved leading label (platform
    ///     container, document type, channel, or host) — resolving it needs the
    ///     platform registry, so the caller supplies it.
    ///   - formattedDate: the save date, already formatted by the caller's
    ///     `DateFormatter` (locale/timezone dependent, so kept out of here).
    ///   - showReadingTime: the `ReaderSettings.showReadingTime` toggle.
    ///   - showReadingProgress: the `ReaderSettings.showReadingProgress` toggle.
    ///   - isRescuing: whether a URL-rescue attempt is in flight for this item,
    ///     so a `.failed` row reads "trying harder…" instead of "pull to retry".
    public static func parts(
        for item: ReadingListItem,
        leadingLabel: String,
        formattedDate: String,
        showReadingTime: Bool,
        showReadingProgress: Bool,
        isRescuing: Bool = false
    ) -> [String] {
        var parts = [leadingLabel, formattedDate]

        if showReadingTime, let minutes = readingTimeMinutes(wordCount: item.wordCount) {
            parts.append(L10n.string("\(minutes) min"))
        }
        if showReadingProgress, item.readState != .read,
           let progress = item.readingProgress, progress > 0.01 {
            parts.append("\(Int(progress * 100))%")
        }

        for (destinationID, state) in item.sendStates.sorted(by: { $0.key < $1.key }) {
            let name = destinationNames[destinationID] ?? destinationID
            switch state {
            case .sent: parts.append(L10n.string("sent to \(name)"))
            case .failed: parts.append(L10n.string("\(name) send failed"))
            case .queued: parts.append(L10n.string("sending to \(name)…"))
            }
        }

        switch item.state {
        case .pending: parts.append(L10n.string("downloading…"))
        case .failed:
            parts.append(isRescuing
                ? L10n.string("trying harder…")
                : L10n.string("pull to retry"))
        case .needsCaptcha: parts.append(L10n.string("tap to unlock"))
        case .ready: break
        }

        return parts
    }

    /// Estimated reading time in whole minutes (rounded up, floored at 1), or
    /// nil when there's no positive word count to estimate from.
    public static func readingTimeMinutes(wordCount: Int?) -> Int? {
        guard let words = wordCount, words > 0 else { return nil }
        return max(1, Int((Double(words) / wordsPerMinute).rounded(.up)))
    }
}
