//
//  PasteboardLinkProbe.swift
//  Luna
//

import UIKit

/// The clipboard bookkeeping behind every deck's synthetic leading paste card:
/// "is there probably a link on the clipboard, and is it still the same one?"
///
/// Extracted because `ArticleCardsViewController` and
/// `SavedMediaCardsViewController` had this identical 20-line dance twice, and it
/// is the part with the subtle rules — every branch is a privacy or a staleness
/// guard, and a copy that drifts either leaks a clipboard read or shows a card for
/// contents the user has already replaced.
///
/// Deliberately NOT a shared card *state*: the two decks' state machines are
/// genuinely different (the reader's ends at a save candidate, the downloader's at
/// an expiring temporary download), so each keeps its own enum. What they share is
/// this change-count discipline.
///
/// **The privacy contract.** `detectPatterns` reveals only that a probable URL
/// exists and does not notify the user or hand over the value. The value itself is
/// read exactly once, from the `UIPasteControl` the card shows — an implicitly
/// authorized read — and validated back against the change count that was probed.
/// Nothing here ever touches `UIPasteboard.string`.
final class PasteboardLinkProbe {

    /// The change count whose contents were already acted on (saved, downloaded,
    /// dismissed). While the clipboard still holds them the card stays away.
    private(set) var consumedChangeCount: Int?

    private var pasteboard: UIPasteboard { .general }

    var currentChangeCount: Int { pasteboard.changeCount }

    /// Marks these clipboard contents as dealt with (saved, downloaded, dismissed).
    /// Takes the change count the host captured when it started the work rather
    /// than reading the live one, so a clipboard that moved on mid-save doesn't
    /// suppress a card for the NEW contents.
    func consume(_ changeCount: Int) {
        consumedChangeCount = changeCount
    }

    /// Whether a value handed over by a paste control still corresponds to the
    /// contents that were probed. A changed clipboard mid-flight invalidates it.
    func isStillCurrent(_ changeCount: Int) -> Bool {
        pasteboard.changeCount == changeCount
    }

    /// Runs the probe.
    ///
    /// - Parameters:
    ///   - stateChangeCount: the change count the host's existing card was built
    ///     for, or nil when it has no card. Equal to the live count ⇒ nothing to do.
    ///   - clear: drop any existing card. Called synchronously, and only when the
    ///     clipboard has actually moved on — each host does its own cleanup here
    ///     (the downloader also deletes a temporary file).
    ///   - offer: a probable web URL exists for the given change count; show the
    ///     placeholder card. Always called on the main queue, and never for a
    ///     change count that is no longer current.
    func probe(
        stateChangeCount: Int?,
        clear: () -> Void,
        offer: @escaping (Int) -> Void
    ) {
        let changeCount = pasteboard.changeCount
        // Already acted on: the card would just offer the same thing again.
        if consumedChangeCount == changeCount {
            clear()
            return
        }
        // The existing card already describes these contents.
        guard stateChangeCount != changeCount else { return }
        clear()
        pasteboard.detectPatterns(for: [\.probableWebURL]) { result in
            DispatchQueue.main.async {
                // The clipboard can change between the probe and its answer; a
                // placeholder for superseded contents would read the wrong value.
                guard UIPasteboard.general.changeCount == changeCount else { return }
                guard (try? result.get())?.contains(\.probableWebURL) == true else { return }
                offer(changeCount)
            }
        }
    }
}
