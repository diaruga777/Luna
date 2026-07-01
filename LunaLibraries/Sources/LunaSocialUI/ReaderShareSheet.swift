//
//  ReaderShareSheet.swift
//  Luna
//

import LunaSocial
import LunaDesignSystem
import UIKit

/// The reader's share affordance: a custom medium-detent bottom sheet offering
/// up to four explicit options — send to the suggested friend (one tap), pick a
/// friend, share the link, or share the article as an EPUB. Replaces the old
/// `UIAlertController(.actionSheet)`. The rows' actions are injected so the
/// sheet stays UI-only; `AppReaderShareProvider` wires them to the social /
/// export stack.
public final class ReaderShareSheet: UIViewController {

    /// One tappable option. `isPrimary` gives the suggested-friend row an accent
    /// fill; the rest are plain.
    public struct Row {
        public let title: String
        public let systemImage: String
        public let isPrimary: Bool
        public let action: () -> Void

        public init(title: String, systemImage: String, isPrimary: Bool, action: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.isPrimary = isPrimary
            self.action = action
        }
    }

    /// Builds the ordered rows. The suggested-friend row is included only when a
    /// suggestion name is present — pure, so the ordering/visibility is testable.
    public static func rows(
        suggestedFriendName: String?,
        includeEbook: Bool,
        onSendToSuggested: @escaping () -> Void,
        onPickFriend: @escaping () -> Void,
        onShareLink: @escaping () -> Void,
        onShareEbook: @escaping () -> Void
    ) -> [Row] {
        var rows: [Row] = []
        if let name = suggestedFriendName {
            rows.append(Row(
                title: "Send to \(name)", systemImage: "paperplane.fill",
                isPrimary: true, action: onSendToSuggested))
        }
        rows.append(Row(
            title: "Send to a Friend…", systemImage: "person.2",
            isPrimary: false, action: onPickFriend))
        rows.append(Row(
            title: "Share Link…", systemImage: "link",
            isPrimary: false, action: onShareLink))
        // eBook export only applies to readable articles, not media / platform posts.
        if includeEbook {
            rows.append(Row(
                title: "Share eBook…", systemImage: "book",
                isPrimary: false, action: onShareEbook))
        }
        return rows
    }

    private let rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows
        super.init(nibName: nil, bundle: nil)
        if let sheet = sheetPresentationController {
            // Just tall enough for the title + buttons + a bottom inset (no
            // wasted half-screen). `rowCount` is captured (not `self`) to avoid a
            // retain cycle through the presentation controller.
            let rowCount = rows.count
            sheet.detents = [.custom(identifier: .init("shareContent")) { _ in
                let titleBlock: CGFloat = 24 + 30 + 20
                let buttons = CGFloat(rowCount) * 52 + CGFloat(max(0, rowCount - 1)) * 12
                return titleBlock + buttons + 44
            }]
            sheet.prefersGrabberVisible = true
            // Round the top corners to roughly match the device's screen corners.
            sheet.preferredCornerRadius = 44
        }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    /// Convenience: build the sheet and present it from `presenter`.
    public static func present(from presenter: UIViewController, rows: [Row]) {
        presenter.present(ReaderShareSheet(rows: rows), animated: true)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "Share"
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [titleLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, row) in rows.enumerated() {
            stack.addArrangedSubview(makeButton(for: row, tag: index))
        }

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func makeButton(for row: Row, tag: Int) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = row.title
        config.image = UIImage(systemName: row.systemImage)
        config.imagePadding = 10
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        config.baseForegroundColor = row.isPrimary ? .white : GlassStyle.readingAccent
        if row.isPrimary {
            config.background.backgroundColor = GlassStyle.readingAccent
            config.background.cornerRadius = 14
        } else {
            config.background.backgroundColor = .secondarySystemBackground
            config.background.cornerRadius = 14
        }
        config.titleAlignment = .leading

        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.tag = tag
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        button.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc private func rowTapped(_ sender: UIButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let action = rows[sender.tag].action
        // Dismiss first so the action can present its own sheet on the original
        // presenter without a "already presenting" conflict.
        dismiss(animated: true) { action() }
    }
}
