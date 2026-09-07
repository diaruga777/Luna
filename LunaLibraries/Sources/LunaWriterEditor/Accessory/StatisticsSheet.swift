//
//  StatisticsSheet.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterText

/// Every count the editor keeps, shown when the bar is tapped.
public final class StatisticsSheet: UIViewController {

    private let stats: TextStatistics.Stats
    private let goal: WritingGoal?

    public init(stats: TextStatistics.Stats, goal: WritingGoal?) {
        self.stats = stats
        self.goal = goal
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("WriterEditor_statisticsTitle")
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        for row in rows() {
            stack.addArrangedSubview(makeRow(name: row.0, value: row.1))
        }
        if let goal {
            let done = StatisticsFormatting.measure(stats, in: goal.unit)
            stack.addArrangedSubview(makeRow(
                name: L10n.string("WriterEditor_statisticsGoal"),
                value: L10n.string(
                    "WriterEditor_statisticsGoalProgress", done as CVarArg, goal.target as CVarArg)))
            let bar = MoonHorizonProgressBar()
            bar.showsActivityPulse = false
            bar.setProgress(Float(StatisticsFormatting.fraction(of: stats, against: goal)), animated: false)
            stack.addArrangedSubview(bar)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
    }

    private func rows() -> [(String, String)] {
        [
            (L10n.string("WriterEditor_statisticsWords"), "\(stats.words)"),
            (L10n.string("WriterEditor_statisticsCharacters"), "\(stats.characters)"),
            (L10n.string("WriterEditor_statisticsCharactersNoSpaces"), "\(stats.charactersWithoutSpaces)"),
            (L10n.string("WriterEditor_statisticsSentences"), "\(stats.sentences)"),
            (L10n.string("WriterEditor_statisticsParagraphs"), "\(stats.paragraphs)"),
            (L10n.string("WriterEditor_statisticsReadingTime"), StatisticsFormatting.readingTime(stats.readingTime)),
        ]
    }

    private func makeRow(name: String, value: String) -> UIView {
        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.textColor = LunaColors.secondaryText

        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.textColor = LunaColors.primaryText
        valueLabel.textAlignment = .right

        let row = UIStackView(arrangedSubviews: [nameLabel, valueLabel])
        row.axis = .horizontal
        row.spacing = 12
        return row
    }
}
