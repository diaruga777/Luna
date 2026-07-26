//
//  ReaderShareSheet.swift
//  Luna
//

import LunaSocial
import LunaDesignSystem
import UIKit
import LunaModels

/// The reader's share options: copy the link, share the link, mail it to a
/// contact, or export the article as an EPUB.
///
/// `menu(rows:)` is the primary presentation — a native `UIMenu` hung off the
/// share button, so the system renders it as a Liquid Glass popover and gives the
/// press-and-slide-to-pick gesture for free. The bottom sheet this class still
/// draws is the fallback for the few share entry points that aren't a button we
/// own (a context-menu action, the archive tray). Both are built from the same
/// `rows`, so the wording never diverges. The actions are injected so this stays
/// UI-only; `AppReaderShareProvider` wires them to the social / export stack.
public final class ReaderShareSheet: UIViewController {

    /// One tappable option.
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

    /// Builds the ordered rows.
    public static func rows(
        includeEbook: Bool,
        onPickFriend: @escaping () -> Void,
        onShareLink: @escaping () -> Void,
        onCopyLink: @escaping () -> Void,
        onShareEbook: @escaping () -> Void
    ) -> [Row] {
        var rows: [Row] = []
        rows.append(Row(
            title: L10n.string("Copy link"), systemImage: "doc.on.doc",
            isPrimary: false, action: onCopyLink))
        rows.append(Row(
            title: L10n.string("Share link"), systemImage: "square.and.arrow.up",
            isPrimary: false, action: onShareLink))
        rows.append(Row(
            title: L10n.string("Send as email"), systemImage: "envelope",
            isPrimary: false, action: onPickFriend))
        // eBook export only applies to readable articles, not media / platform posts.
        if includeEbook {
            rows.append(Row(
                title: L10n.string("Share .epub"), systemImage: "book",
                isPrimary: false, action: onShareEbook))
        }
        return rows
    }

    /// The same options as a native menu, for hanging off a share button. Ordering is
    /// pinned (`.displayInline` inside a fixed-order parent at the call site) so the
    /// list reads top-to-bottom exactly as `rows` builds it, whichever edge of the
    /// screen the popover opens toward.
    public static func menu(rows: [Row]) -> UIMenu {
        UIMenu(children: rows.map { row in
            UIAction(title: row.title, image: UIImage(systemName: row.systemImage)) { _ in
                row.action()
            }
        })
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
        view.backgroundColor = LunaColors.background

        let titleLabel = UILabel()
        titleLabel.text = L10n.string("Share")
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
            config.background.backgroundColor = LunaColors.secondaryBackground
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
