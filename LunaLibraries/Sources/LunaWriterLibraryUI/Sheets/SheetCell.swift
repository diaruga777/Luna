import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels

/// A document preview with a clear title, short excerpt, and its location/date.
public final class SheetCell: UICollectionViewListCell {

    public static let reuseIdentifier = "SheetCell"

    private let titleLabel = UILabel()
    private let chapterNumber = UILabel()
    private let chapterBadge = UIView()
    private let snippetLabel = UILabel()
    private let dateLabel = UILabel()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Below this, `RelativeDateTimeFormatter` reads as "in 0 seconds" for a
    /// sheet that just autosaved — there is no unit small enough to word it
    /// naturally, so this floor reads it as "Just now" instead.
    private static let justNowThreshold: TimeInterval = 60

    private static func relativeDateText(for date: Date) -> String {
        guard abs(date.timeIntervalSinceNow) >= justNowThreshold else {
            return L10n.string("WriterLibrary_sheets_justNow")
        }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// How many keyword chips a row shows before folding the rest into a
    /// "+N" chip — unbounded, they run past the cell's trailing edge (organiser #22).
    private static let maxVisibleChips = 3

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    private func configureViews() {
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        chapterNumber.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .medium))
        chapterNumber.adjustsFontForContentSizeCategory = true
        chapterNumber.textColor = LunaColors.secondaryText
        chapterNumber.textAlignment = .center
        chapterNumber.adjustsFontSizeToFitWidth = true
        chapterNumber.minimumScaleFactor = 0.65
        chapterNumber.translatesAutoresizingMaskIntoConstraints = false
        chapterBadge.backgroundColor = .tertiarySystemFill
        chapterBadge.layer.cornerRadius = 8
        chapterBadge.layer.cornerCurve = .continuous
        chapterBadge.isUserInteractionEnabled = false
        chapterBadge.addSubview(chapterNumber)
        chapterBadge.isHidden = true
        let badgeWidth = chapterBadge.widthAnchor.constraint(equalToConstant: 36)
        badgeWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            badgeWidth,
            chapterBadge.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            chapterNumber.leadingAnchor.constraint(equalTo: chapterBadge.leadingAnchor, constant: 8),
            chapterNumber.trailingAnchor.constraint(equalTo: chapterBadge.trailingAnchor, constant: -8),
            chapterNumber.centerYAnchor.constraint(equalTo: chapterBadge.centerYAnchor),
            chapterNumber.topAnchor.constraint(greaterThanOrEqualTo: chapterBadge.topAnchor, constant: 8),
            chapterNumber.bottomAnchor.constraint(lessThanOrEqualTo: chapterBadge.bottomAnchor, constant: -8),
        ])
        titleLabel.textColor = LunaColors.primaryText

        snippetLabel.font = .preferredFont(forTextStyle: .subheadline)
        snippetLabel.adjustsFontForContentSizeCategory = true
        snippetLabel.textColor = LunaColors.secondaryText
        snippetLabel.numberOfLines = 2

        dateLabel.font = .preferredFont(forTextStyle: .caption1)
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textColor = .secondaryLabel
        dateLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [titleLabel, snippetLabel, dateLabel])
        stack.axis = .vertical
        stack.spacing = 4
        let row = UIStackView(arrangedSubviews: [chapterBadge, stack])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)


        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    public func configure(with document: WriterDocument, chapterOrdinal: Int? = nil, location: String? = nil) {
        chapterBadge.isHidden = chapterOrdinal == nil
        chapterNumber.text = chapterOrdinal.map { String($0) }
        chapterNumber.accessibilityLabel = chapterOrdinal.map { L10n.string("WriterStorage_chapterTitle", Int64($0)) }
        snippetLabel.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 2
        titleLabel.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 2
        titleLabel.text = document.title.isEmpty ? L10n.string("Common_untitled") : document.title
        snippetLabel.text = document.snippet
        snippetLabel.isHidden = document.snippet.isEmpty
        dateLabel.text = [Self.relativeDateText(for: document.updatedAt), location].compactMap { $0 }.joined(separator: " · ")
        accessibilityLabel = [chapterNumber.accessibilityLabel, titleLabel.text, snippetLabel.text, dateLabel.text]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        isAccessibilityElement = true
        accessibilityTraits.insert(.button)

    }

    /// Words per minute a reader gets through, for the `.readingMinutes` goal
    /// unit. Matches the estimate `StatisticsSheet` and the editor's own
    /// reading-time display use.
    private static let wordsPerReadingMinute = 250

    /// How far a sheet is toward its goal, `0...1`. `.atMost` reverses the
    /// sense: a sheet under the ceiling reads as fully on track.
    static func progress(for document: WriterDocument, goal: WritingGoal) -> Float {
        guard goal.target > 0 else { return 0 }
        let count: Int
        switch goal.unit {
        case .words: count = document.wordCount
        case .characters: count = document.characterCount
        case .sentences: count = document.sentenceCount
        case .readingMinutes: count = document.wordCount / wordsPerReadingMinute
        }
        switch goal.mode {
        case .atLeast, .about:
            return Float(min(1.0, Double(count) / Double(goal.target)))
        case .atMost:
            return Float(count <= goal.target ? 1.0 : Double(goal.target) / Double(count))
        }
    }

    private static func chip(for keyword: String) -> UIView {
        let label = UILabel()
        label.text = keyword
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = LunaColors.secondaryText
        label.textAlignment = .center
        let container = UIView()
        container.backgroundColor = LunaColors.tertiaryFill
        container.layer.cornerRadius = 8
        container.layer.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
        ])
        return container
    }
}

/// One row in the Inbox's unattached-notes section: the note's text, a glyph
/// for where it came from, and an "Attach to…" button.
public final class UnattachedNoteCell: UICollectionViewListCell {

    public static let reuseIdentifier = "UnattachedNoteCell"

    public let attachButton = UIButton(type: .system)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        attachButton.setImage(UIImage(systemName: "link"), for: .normal)
        attachButton.accessibilityLabel = L10n.string("WriterLibrary_polish_linkDocumentLabel")
        attachButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { nil }

    public func configure(with note: WriterNote, linkedTitles: [String] = []) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = note.text
        content.textProperties.numberOfLines = 0
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryText = linkedTitles.isEmpty ? L10n.string("WriterLibrary_polish_unlinkedNote") : linkedTitles.joined(separator: " · ")
        content.secondaryTextProperties.numberOfLines = 0
        content.textToSecondaryTextVerticalPadding = 8
        content.directionalLayoutMargins.top = 16
        content.directionalLayoutMargins.bottom = 16
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        contentConfiguration = content
        accessories = [.customView(configuration: .init(customView: attachButton, placement: .trailing()))]
    }
}
