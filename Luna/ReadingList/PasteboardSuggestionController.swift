//
//  PasteboardSuggestionController.swift
//  Luna
//

import LunaModels
import LunaReadingList
import LunaReadingListUI
import LunaStorage
import LunaURLClassification
import UIKit

/// Owns the "From Pasteboard" suggestion state for `ReadingListViewController`:
/// whether there's a readable/supported URL on the clipboard worth surfacing,
/// while it's still being evaluated, and the resolved candidate once it is.
/// Self-registers for pasteboard-relevant app-activation so the host doesn't
/// have to route that notification through by hand.
protocol PasteboardSuggestionControllerDelegate: AnyObject {
    /// The suggestion state changed (a spinner appeared, resolved, or cleared)
    /// — rebuild whatever shows it.
    func pasteboardSuggestionDidChange(_ controller: PasteboardSuggestionController)
    /// `preview()` resolved a not-yet-saved item (a platform post, or a plain
    /// article with content already in hand) — open it without saving.
    func pasteboardSuggestion(
        _ controller: PasteboardSuggestionController,
        openTransient item: ReadingListItem, for candidate: PasteboardCandidate)
    /// `preview()` had to save the candidate first (a paywalled URL awaiting
    /// archive unlock) — open the now-real, now-persisted item.
    func pasteboardSuggestion(_ controller: PasteboardSuggestionController, openSaved item: ReadingListItem)
}

@MainActor
final class PasteboardSuggestionController: NSObject {

    weak var delegate: PasteboardSuggestionControllerDelegate?

    /// A readable URL found on the system pasteboard, shown as a one-tap "From
    /// Pasteboard" row until saved. nil when there's nothing to suggest.
    private(set) var pasteboardCandidate: PasteboardCandidate?
    /// While set, the pasteboard URL whose preview is still being fetched — the
    /// row shows a spinner until the candidate (or nil) resolves.
    private(set) var evaluatingPasteboardURL: String?
    /// The pasteboard `changeCount` last evaluated, so we only read its contents
    /// (which shows the system paste banner) when it has actually changed.
    private var lastCheckedPasteboardChangeCount = -1

    private let surface: AppSurface?

    init(surface: AppSurface?) {
        self.surface = surface
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(evaluate),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// If the pasteboard holds a new URL with extractable content, surface it as
    /// the top "From Pasteboard" row. Gated on `changeCount` so the system paste
    /// banner shows at most once per newly copied URL.
    @objc func evaluate() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != lastCheckedPasteboardChangeCount else { return }
        lastCheckedPasteboardChangeCount = pasteboard.changeCount

        guard pasteboard.hasURLs, let url = pasteboard.url else {
            // Pasteboard changed to something with no URL — drop any stale row.
            drop()
            return
        }
        // A non-ingestable or already-saved copy also invalidates whatever the
        // row was showing — the pasteboard no longer holds that URL.
        guard let normalizedURL = URLUnwrapper.ingestURL(from: url.absoluteString) else {
            drop()
            return
        }
        let urlString = normalizedURL.absoluteString
        guard ReadingListStore.shared.item(forURLString: urlString) == nil else {
            drop()
            return
        }
        // Show a spinner row immediately, then fill it in once the preview
        // (content + thumbnail) resolves.
        pasteboardCandidate = nil
        evaluatingPasteboardURL = urlString
        delegate?.pasteboardSuggestionDidChange(self)
        Task { [weak self] in
            let candidate = await PasteboardSuggester.shared.evaluate(urlString: urlString)
            guard let self, self.evaluatingPasteboardURL == urlString else { return }
            self.evaluatingPasteboardURL = nil
            // Only suggest what THIS app's surface can show: saving an
            // article from the Price Tracker app would store it fine but
            // make it vanish from this list — a save that looks discarded.
            self.pasteboardCandidate = candidate.flatMap {
                self.surfaceAllows($0) ? $0 : nil
            }
            self.delegate?.pasteboardSuggestionDidChange(self)
        }
    }

    /// Whether a saved `candidate` would actually appear on this app's surface.
    /// The combined list (surface == nil) shows everything.
    private func surfaceAllows(_ candidate: PasteboardCandidate) -> Bool {
        guard let surface else { return true }
        switch surface {
        case .reader: return candidate.platform == nil
        case .downloader: return candidate.platform != nil
        case .priceTracker: return false // the suggester never detects products
        }
    }

    private func drop() {
        if pasteboardCandidate != nil || evaluatingPasteboardURL != nil {
            pasteboardCandidate = nil
            evaluatingPasteboardURL = nil
            delegate?.pasteboardSuggestionDidChange(self)
        }
    }

    /// The trailing Save button: persists the candidate (it then moves into the
    /// Reading section) without opening it.
    func save() {
        guard let candidate = pasteboardCandidate else { return }
        pasteboardCandidate = nil
        evaluatingPasteboardURL = nil
        delegate?.pasteboardSuggestionDidChange(self)   // drop the row; the saved item arrives via the notification
        if let content = candidate.content {
            Task {
                await ReadingListIngestor.shared.saveNewWithContent(
                    urlString: candidate.urlString, content: content, source: .paste)
            }
        } else {
            Task {
                await ReadingListIngestor.shared.handleSavePress(
                    urlString: candidate.urlString, source: .paste)
            }
        }
    }

    /// Tapping the row PREVIEWS the candidate without saving it (a transient item;
    /// the row stays until the user taps Save).
    func preview() {
        guard let candidate = pasteboardCandidate else { return }
        let transient = displayItem(for: candidate)

        if candidate.platform != nil {
            delegate?.pasteboardSuggestion(self, openTransient: transient, for: candidate)
        } else if candidate.requiresUnlock {
            pasteboardCandidate = nil
            evaluatingPasteboardURL = nil
            delegate?.pasteboardSuggestionDidChange(self)
            Task { [weak self] in
                let result = await ReadingListIngestor.shared.handleSavePress(
                    urlString: candidate.urlString, source: .paste)
                guard let self else { return }
                let resultItem: ReadingListItem?
                switch result {
                case .saved(let saved), .savedNeedsOwnerInstall(let saved, _),
                     .sentToEreaders(let saved),
                     .sentToFriends(let saved), .friendPromptRequested(let saved):
                    resultItem = saved
                case .ignored: resultItem = nil
                case .blockedByInterop:
                    // Unpaid cross-surface paste — discarded; the ingest
                    // gate has already shown the interop prompt.
                    return
                }
                let item = resultItem
                    .flatMap { ReadingListStore.shared.item(withID: $0.id) }
                    ?? ReadingListStore.shared.item(forURLString: candidate.urlString)
                guard let item else { return }
                self.delegate?.pasteboardSuggestion(self, openSaved: item)
            }
        } else if candidate.content != nil {
            delegate?.pasteboardSuggestion(self, openTransient: transient, for: candidate)
        }
    }

    /// The current suggestion rendered as a transient row item — a `.pending`
    /// placeholder while still evaluating, else the resolved candidate. Clears
    /// (silently — the caller is already mid-rebuild) a resolved candidate
    /// that's since been saved by some other path, rather than keep showing a
    /// stale suggestion for an already-saved URL.
    func currentDisplayItem() -> ReadingListItem? {
        if let candidate = pasteboardCandidate {
            guard ReadingListStore.shared.item(forURLString: candidate.urlString) == nil else {
                pasteboardCandidate = nil
                return nil
            }
            return displayItem(for: candidate)
        }
        if let evaluatingURL = evaluatingPasteboardURL {
            var loading = ReadingListItem(urlString: evaluatingURL)
            loading.state = .pending
            return loading
        }
        return nil
    }

    /// A transient (unsaved) item used to render the pasteboard suggestion row.
    private func displayItem(for candidate: PasteboardCandidate) -> ReadingListItem {
        var item = ReadingListItem(urlString: candidate.urlString)
        item.title = candidate.title
        item.state = candidate.requiresUnlock ? .needsCaptcha : .ready
        item.channelName = candidate.channelName
        item.platform = candidate.platform
        return item
    }
}
