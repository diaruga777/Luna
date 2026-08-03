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

    /// One row per live kind, in the app's kind order. The visible one is
    /// `rows[index]`; the rest are parked off-slot.
    private(set) var rows: [UtilURLRow] = []
    private(set) var displays: [WeeklySaveDisplay] = []
    private var index = 0

    /// Whether the card should give this slot any room at all.
    var isEmpty: Bool { displays.isEmpty }

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
        // Rows slide within this slot and must never bleed onto the card.
        clipsToBounds = true
        layer.cornerRadius = UtilURLRow.cornerRadius
        layer.cornerCurve = .continuous
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
        let updated = store.liveDisplays(for: WeeklySaveKind.kinds(for: app))
        guard updated != displays else { return false }
        displays = updated
        index = min(index, max(0, updated.count - 1))
        rebuildRows()
        setNeedsLayout()
        let presenceChanged = wasEmpty != isEmpty
        if presenceChanged { onPresenceChange?() }
        return presenceChanged
    }

    private func rebuildRows() {
        for row in rows { row.removeFromSuperview() }
        rows = displays.map { display in
            let row = UtilURLRow(style: .saveOfTheWeek)
            configure(row, with: display)
            addSubview(row)
            return row
        }
        updateRowVisibility()
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

    /// Only the current row is on screen; the others wait one slot-width away
    /// so a slide has somewhere to come from.
    private func updateRowVisibility() {
        for (offset, row) in rows.enumerated() {
            row.isHidden = offset != index
        }
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
        for row in rows where !row.isHidden {
            row.frame = bounds
        }
    }
}
