//
//  WeeklySaveRowHost.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaWeekly
import UIKit

/// The util card's Save of the Week slot.
///
/// It owns whatever rows the local store currently has for THIS app's kinds —
/// none (the slot collapses and the card reflows without it), one, or, in the
/// central app, up to three that take turns in the same place. Everything it
/// draws comes from `WeeklySaveStore`; it never fetches.
final class WeeklySaveRowHost: UIView {
    /// Tapping a row saves it, exactly like a recent-history row.
    var onSave: ((_ urlString: String, _ sourceView: UIView) -> Void)?
    /// The card asks for a relayout whenever the slot appears or disappears.
    var onPresenceChange: (() -> Void)?

    private let store: WeeklySaveStore
    private let app: LunaApp
    private let now: () -> Date

    /// Rows live inside a clipping child so a slide reads as a row entering the
    /// slot. The HOST itself must not clip: the replacement corona overhangs it
    /// on every side, and that overhang is the effect.
    private let clip = UIView()

    /// One row per live kind, in the app's kind order. The visible one is
    /// `rows[index]`.
    private(set) var rows: [UtilURLRow] = []
    private(set) var displays: [WeeklySaveDisplay] = []
    private var index = 0
    /// Held for the whole run — a transition that only the animation retains is
    /// the carousel's classic disappearing-act bug.
    private var replacement: WeeklyRowEclipseTransition?

    /// Whether the card should give this slot any room at all.
    var isEmpty: Bool { displays.isEmpty }

    /// Whether a replacement is mid-flight (the cycle pauses while it is).
    var isReplacing: Bool { replacement != nil }

    /// The carousel's own Reduce Motion crossfade length
    /// (`CarouselAnimationTiming.crossfadeDuration`, which is private to it).
    static let reduceMotionCrossfade: TimeInterval = 0.28

    init(
        store: WeeklySaveStore = .shared,
        app: LunaApp = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.app = app
        self.now = now
        super.init(frame: .zero)
        accessibilityIdentifier = "utilCard.weeklyHost"
        clipsToBounds = false
        clip.clipsToBounds = true
        clip.layer.cornerRadius = UtilURLRow.cornerRadius
        clip.layer.cornerCurve = .continuous
        addSubview(clip)
        reload(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Content

    /// Rebuilds from the store. Returns true when the slot's presence changed,
    /// which is the card's cue to reflow.
    @discardableResult
    func reload(animated: Bool) -> Bool {
        let wasEmpty = isEmpty
        let previous = displays
        let updated = store.liveDisplays(for: WeeklySaveKind.kinds(for: app))
        guard updated != previous else { return false }
        displays = updated
        let previousIndex = index
        index = min(index, max(0, updated.count - 1))

        // The one case worth an eclipse: the row on screen right now kept its
        // place and swapped its content. Anything else (a row appearing, the
        // last one leaving, the set changing size) is the card's own fade.
        if animated, !wasEmpty, !isEmpty,
           previous.count == updated.count, previousIndex == index,
           previous.indices.contains(index),
           previous[index].save.kind == updated[index].save.kind,
           previous[index].save != updated[index].save,
           bounds.width > 1, let outgoing = rows.indices.contains(index) ? rows[index] : nil
        {
            replaceCurrentRow(outgoing: outgoing, with: updated[index])
            rebuildOffscreenRows(keeping: index)
            return false
        }

        rebuildRows()
        setNeedsLayout()
        let presenceChanged = wasEmpty != isEmpty
        if presenceChanged { onPresenceChange?() }
        return presenceChanged
    }

    private func rebuildRows() {
        replacement?.finish()
        replacement = nil
        for row in rows { row.removeFromSuperview() }
        rows = displays.map(makeRow)
        updateRowVisibility()
    }

    /// After an in-place replacement the OTHER kinds' rows may also have moved
    /// on, so they are rebuilt around the row the eclipse is animating.
    private func rebuildOffscreenRows(keeping keptIndex: Int) {
        for (offset, row) in rows.enumerated() where offset != keptIndex {
            row.removeFromSuperview()
        }
        var rebuilt: [UtilURLRow] = []
        for (offset, display) in displays.enumerated() {
            if offset == keptIndex, rows.indices.contains(keptIndex) {
                rebuilt.append(rows[keptIndex])
            } else {
                rebuilt.append(makeRow(display))
            }
        }
        rows = rebuilt
        updateRowVisibility()
    }

    private func makeRow(_ display: WeeklySaveDisplay) -> UtilURLRow {
        let row = UtilURLRow(style: .saveOfTheWeek)
        configure(row, with: display)
        clip.addSubview(row)
        return row
    }

    private func configure(_ row: UtilURLRow, with display: WeeklySaveDisplay) {
        row.configure(
            RecentURLPreview(
                urlString: display.save.urlString,
                title: display.title,
                subtitle: display.subtitleHost,
                kind: Self.previewKind(display.save.kind),
                imageData: display.imageData),
            weeklyLabel: WeeklySaveLabels.subtitle(
                for: app, monthTier: display.save.isMonthTier(now: now())))
        row.onTap = { [weak self, weak row] in
            guard let self, let row else { return }
            self.onSave?(display.save.urlString, row)
        }
    }

    /// Only the current row is on screen; the rest wait hidden.
    private func updateRowVisibility() {
        for (offset, row) in rows.enumerated() where !(replacement != nil && offset == index) {
            row.isHidden = offset != index
        }
    }

    // MARK: - Replacement

    private func replaceCurrentRow(outgoing: UtilURLRow, with display: WeeklySaveDisplay) {
        replacement?.finish()
        let incoming = makeRow(display)
        incoming.isHidden = false
        rows[index] = incoming
        clip.frame = bounds
        outgoing.frame = clip.bounds

        if UIAccessibility.isReduceMotionEnabled {
            // Carousel precedent: no travel, no corona — just a crossfade.
            incoming.alpha = 0
            UIView.animate(withDuration: Self.reduceMotionCrossfade) {
                incoming.alpha = 1
                outgoing.alpha = 0
            } completion: { _ in
                outgoing.removeFromSuperview()
            }
            return
        }

        let transition = WeeklyRowEclipseTransition(
            host: self, clip: clip, outgoing: outgoing, incoming: incoming
        ) { [weak self] in
            self?.replacement = nil
        }
        replacement = transition
        transition.start()
    }

    private static func previewKind(_ kind: WeeklySaveKind) -> RecentURLPreview.Kind {
        switch kind {
        case .article: return .article
        case .media: return .media
        case .product: return .product
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
        // A row mid-transform is being animated; assigning `frame` under a
        // non-identity transform would fight it.
        for row in rows where !row.isHidden && row.transform.isIdentity {
            row.frame = clip.bounds
        }
    }
}
