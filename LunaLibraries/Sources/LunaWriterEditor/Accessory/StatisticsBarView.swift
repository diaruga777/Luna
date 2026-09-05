//
//  StatisticsBarView.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterText

public protocol StatisticsBarViewDelegate: AnyObject {
    func statisticsBarViewDidSelect(_ view: StatisticsBarView)
}

/// The count under the text: words, reading time, and the goal's progress.
public final class StatisticsBarView: UIView {

    public static let height: CGFloat = 28

    public weak var delegate: StatisticsBarViewDelegate?

    private let label = UILabel()
    private let progress = MoonHorizonProgressBar()
    public var saveFailed = false {
        didSet { update(stats: stats, goal: goal) }
    }

    public private(set) var stats = TextStatistics.Stats(
        words: 0, characters: 0, charactersWithoutSpaces: 0, sentences: 0, paragraphs: 0, readingTime: 0)
    public private(set) var goal: WritingGoal?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    private func build() {
        backgroundColor = .clear
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = LunaColors.tertiaryText
        progress.showsActivityPulse = false
        progress.isHidden = true

        let stack = UIStackView(arrangedSubviews: [label, progress])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 72),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    public func update(stats: TextStatistics.Stats, goal: WritingGoal?) {
        self.stats = stats
        self.goal = goal
        label.text = saveFailed ? L10n.string("WriterEditor_saveFailed") : Self.summary(stats)
        label.textColor = saveFailed ? .systemRed : LunaColors.tertiaryText
        accessibilityLabel = label.text
        if let goal {
            progress.isHidden = false
            progress.setProgress(Float(Self.fraction(of: stats, against: goal)), animated: true)
        } else {
            progress.isHidden = true
        }
    }

    /// "412 words · 2 min".
    public static func summary(_ stats: TextStatistics.Stats) -> String {
        L10n.string(
            "WriterEditor_statisticsSummary", stats.words as CVarArg, readingTime(stats.readingTime))
    }

    public static func readingTime(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return L10n.string("WriterEditor_statisticsMinutes", minutes as CVarArg)
    }

    /// How far the writing has come against its goal, capped at one.
    public static func fraction(of stats: TextStatistics.Stats, against goal: WritingGoal) -> Double {
        guard goal.target > 0 else { return 0 }
        return min(1, Double(measure(stats, in: goal.unit)) / Double(goal.target))
    }

    public static func measure(_ stats: TextStatistics.Stats, in unit: WritingGoal.Unit) -> Int {
        switch unit {
        case .words: return stats.words
        case .characters: return stats.characters
        case .sentences: return stats.sentences
        case .readingMinutes: return Int((stats.readingTime / 60).rounded())
        }
    }

    @objc private func tapped() {
        delegate?.statisticsBarViewDidSelect(self)
    }
}
