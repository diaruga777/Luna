//
//  ArticleScrubPreview.swift
//  Luna
//
//  A cheap, bounded Reader scrub-preview. It deliberately avoids constructing
//  the full reader hierarchy while preserving the saved reading position.
//

import LunaDesignSystem
import LunaModels
import UIKit

enum ArticleScrubPreviewText {
    static let wordBudget = 170
    private static let contextWordCount = 24

    static func excerpt(
        from content: ArticleContent,
        aroundWordIndex: Int?,
        readingProgress: Double?
    ) -> String {
        let textBlocks = content.blocks.filter { $0.kind != .image && !$0.text.isEmpty }
        guard !textBlocks.isEmpty else { return "No article text available." }

        if let wordIndex = aroundWordIndex, wordIndex > 0 {
            return excerptAroundWord(wordIndex, in: textBlocks)
        }

        let progress = min(max(readingProgress ?? 0, 0), 1)
        let blockIndex = min(Int(progress * Double(textBlocks.count)), textBlocks.count - 1)
        return excerptStartingAtBlock(blockIndex, in: textBlocks, hasEarlierText: blockIndex > 0)
    }

    static func unavailableText(for state: ReadingListItem.State) -> String {
        switch state {
        case .pending: return "Fetching article text…"
        case .failed: return "Couldn't fetch this article."
        case .needsCaptcha: return "Locked — tap to unlock."
        case .ready: return "No article text available."
        }
    }

    private static func excerptAroundWord(
        _ requestedWordIndex: Int,
        in blocks: [ArticleContent.Block]
    ) -> String {
        var globalWordIndex = 0
        var precedingWords: [Substring] = []

        for (blockIndex, block) in blocks.enumerated() {
            let words = block.text.split(whereSeparator: { $0.isWhitespace })
            let blockEnd = globalWordIndex + words.count
            if requestedWordIndex < blockEnd {
                let localIndex = max(requestedWordIndex - globalWordIndex, 0)
                let prefix = precedingWords.suffix(contextWordCount)
                var result = Array(prefix)
                result.append(contentsOf: words.dropFirst(localIndex).prefix(
                    max(wordBudget - result.count, 0)))
                appendWords(
                    from: blocks.dropFirst(blockIndex + 1),
                    to: &result,
                    limit: wordBudget)
                let hasEarlierText = requestedWordIndex > prefix.count
                return format(result, hasEarlierText: hasEarlierText)
            }
            precedingWords.append(contentsOf: words)
            if precedingWords.count > contextWordCount {
                precedingWords.removeFirst(precedingWords.count - contextWordCount)
            }
            globalWordIndex = blockEnd
        }

        // A stale index beyond the current extraction should still preview the
        // article's tail instead of falling back to its title.
        return format(precedingWords, hasEarlierText: true)
    }

    private static func excerptStartingAtBlock(
        _ index: Int,
        in blocks: [ArticleContent.Block],
        hasEarlierText: Bool
    ) -> String {
        var result: [Substring] = []
        appendWords(from: blocks.dropFirst(index), to: &result, limit: wordBudget)
        return format(result, hasEarlierText: hasEarlierText)
    }

    private static func appendWords<S: Sequence>(
        from blocks: S,
        to result: inout [Substring],
        limit: Int
    ) where S.Element == ArticleContent.Block {
        for block in blocks where result.count < limit {
            let remaining = limit - result.count
            result.append(contentsOf: block.text.split(
                whereSeparator: { $0.isWhitespace }).prefix(remaining))
        }
    }

    private static func format(_ words: [Substring], hasEarlierText: Bool) -> String {
        guard !words.isEmpty else { return "No article text available." }
        let bounded = words.prefix(wordBudget).joined(separator: " ")
        let prefix = hasEarlierText ? "… " : ""
        let suffix = words.count >= wordBudget ? " …" : ""
        return prefix + bounded + suffix
    }
}

final class ArticleScrubPreviewViewController: CardContentViewController {
    private let titleText: String
    private let authorText: String?
    private let excerptText: String

    init(title: String, author: String?, excerpt: String) {
        self.titleText = title
        self.authorText = author
        self.excerptText = excerpt
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.isUserInteractionEnabled = false

        let title = UILabel()
        title.text = titleText
        title.font = .preferredFont(forTextStyle: .title1)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 3
        title.textColor = .label

        let author = UILabel()
        author.text = authorText
        author.font = .preferredFont(forTextStyle: .subheadline)
        author.adjustsFontForContentSizeCategory = true
        author.textColor = .secondaryLabel
        author.numberOfLines = 1
        author.isHidden = authorText?.isEmpty != false

        let body = UILabel()
        body.text = excerptText
        body.font = .preferredFont(forTextStyle: .body)
        body.adjustsFontForContentSizeCategory = true
        body.numberOfLines = 0
        body.textColor = .label

        let stack = UIStackView(arrangedSubviews: [title, author, body])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -28),
        ])
    }
}
