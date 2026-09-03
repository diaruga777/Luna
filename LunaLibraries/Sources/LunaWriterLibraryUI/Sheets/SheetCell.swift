import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels

/// One row of the sheets list: title, snippet, relative date, a goal ring
/// when the sheet carries a goal, a favourite dot, and keyword chips.
public final class SheetCell: UICollectionViewListCell {

    public static let reuseIdentifier = "SheetCell"

    private let titleLabel = UILabel()
    private let favoriteGlyph = UIImageView()
    private let snippetLabel = UILabel()
    private let dateLabel = UILabel()
    private let goalBar = MoonHorizonProgressBar()
    private let chipsStack = UIStackView()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    private func configureViews() {
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = LunaColors.primaryText

        favoriteGlyph.image = UIImage(systemName: "star.fill")
        favoriteGlyph.tintColor = LunaColors.primaryText
        favoriteGlyph.setContentHuggingPriority(.required, for: .horizontal)

        snippetLabel.font = .systemFont(ofSize: 13)
        snippetLabel.textColor = LunaColors.secondaryText
        snippetLabel.numberOfLines = 2

        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = LunaColors.tertiaryText

        goalBar.showsActivityPulse = false
        goalBar.isHidden = true

        chipsStack.axis = .horizontal
        chipsStack.spacing = 6
        chipsStack.alignment = .center

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, favoriteGlyph])
        titleRow.axis = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .center

        let metaRow = UIStackView(arrangedSubviews: [dateLabel, goalBar])
        metaRow.axis = .horizontal
        metaRow.spacing = 8
        metaRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [titleRow, snippetLabel, metaRow, chipsStack])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        goalBar.widthAnchor.constraint(equalToConstant: 60).isActive = true
        goalBar.heightAnchor.constraint(equalToConstant: 6).isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    public func configure(with document: WriterDocument) {
        titleLabel.text = document.title.isEmpty ? L10n.string("Common_untitled") : document.title
        favoriteGlyph.isHidden = !document.isFavorite
        snippetLabel.text = document.snippet
        snippetLabel.isHidden = document.snippet.isEmpty
        dateLabel.text = Self.relativeFormatter.localizedString(for: document.updatedAt, relativeTo: Date())

        if let goal = document.goal {
            goalBar.isHidden = false
            goalBar.setProgress(Self.progress(for: document, goal: goal), animated: false)
        } else {
            goalBar.isHidden = true
        }

        chipsStack.arrangedSubviews.forEach {
            chipsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for keyword in document.keywords {
            chipsStack.addArrangedSubview(Self.chip(for: keyword))
        }
    }

    /// How far a sheet is toward its goal, `0...1`. `.atMost` reverses the
    /// sense: a sheet under the ceiling reads as fully on track.
    static func progress(for document: WriterDocument, goal: WritingGoal) -> Float {
        guard goal.target > 0 else { return 0 }
        let count: Int
        switch goal.unit {
        case .words: count = document.wordCount
        case .characters: count = document.characterCount
        case .sentences, .readingMinutes: count = document.wordCount
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

    private let sourceGlyph = UIImageView()
    private let textLabel = UILabel()
    public let attachButton = UIButton(type: .system)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        sourceGlyph.tintColor = LunaColors.secondaryText
        sourceGlyph.setContentHuggingPriority(.required, for: .horizontal)

        textLabel.font = .systemFont(ofSize: 14)
        textLabel.textColor = LunaColors.primaryText
        textLabel.numberOfLines = 2

        attachButton.setTitle(L10n.string("WriterLibrary_sheets_attachToAction"), for: .normal)
        attachButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        attachButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [sourceGlyph, textLabel, attachButton])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public func configure(with note: WriterNote) {
        textLabel.text = note.text
        sourceGlyph.image = UIImage(systemName: Self.symbol(for: note.source))
    }

    private static func symbol(for source: WriterNote.Source) -> String {
        switch source {
        case .typed: return "keyboard"
        case .mention: return "at"
        case .intent: return "bolt"
        case .voice: return "mic"
        }
    }
}
