//
//  ReaderShareSheet.swift
//  Luna
//

import LunaSocial
import LunaDesignSystem
import UIKit
import LunaModels

/// The reader's share options: copy the link, share the link, mail it to a
/// contact, or export the article as a file (EPUB / PDF / Markdown / text).
///
/// `menu(rows:)` is the primary presentation — a native `UIMenu` hung off the
/// share button, so the system renders it as a Liquid Glass popover and gives the
/// press-and-slide-to-pick gesture for free. The bottom sheet this class still
/// draws is the fallback for the few share entry points that aren't a button we
/// own (a context-menu action, the archive tray). Both are built from the same
/// `rows`, so the wording never diverges. The actions are injected so this stays
/// UI-only; `AppReaderShareProvider` wires them to the social / export stack.
///
/// A row with `children` is a submenu: the four export formats hang off one
/// "Export as…" row rather than flattening into the top level, which would
/// double the option list for a choice most shares never touch. In the menu the
/// system draws it as a nested popover; in the fallback sheet it presents a
/// second sheet — see `rowTapped`.
public final class ReaderShareSheet: UIViewController {

    /// One tappable option, or — when `children` is non-empty — a submenu of them.
    public struct Row {
        public let title: String
        public let systemImage: String
        public let isPrimary: Bool
        public let action: () -> Void
        /// Nested options. When non-empty, `action` is not used.
        public let children: [Row]

        public init(title: String, systemImage: String, isPrimary: Bool,
                    children: [Row] = [], action: @escaping () -> Void = {}) {
            self.title = title
            self.systemImage = systemImage
            self.isPrimary = isPrimary
            self.children = children
            self.action = action
        }
    }

    /// Title of the nested export sheet/submenu. Public so a caller presenting
    /// the export options on their own (an article with no link to share) labels
    /// them identically.
    public static var exportTitle: String { L10n.string("Export as…") }

    /// The export-format options, in `ArticleExportFormat.shareMenuFormats`
    /// order (which is NOT `allCases` — `.document` is double-save only).
    public static func exportRows(
        onExport: @escaping (ArticleExportFormat) -> Void
    ) -> [Row] {
        ArticleExportFormat.shareMenuFormats.map { format in
            Row(title: format.displayName, systemImage: format.systemImage,
                isPrimary: false, action: { onExport(format) })
        }
    }

    /// Builds the ordered rows.
    public static func rows(
        includeExport: Bool,
        onPickFriend: @escaping () -> Void,
        onShareLink: @escaping () -> Void,
        onCopyLink: @escaping () -> Void,
        onExport: @escaping (ArticleExportFormat) -> Void
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
        // File export only applies to readable articles, not media / platform posts.
        if includeExport {
            rows.append(Row(
                title: exportTitle, systemImage: "square.and.arrow.down.on.square",
                isPrimary: false, children: exportRows(onExport: onExport)))
        }
        return rows
    }

    /// The same options as a native menu, for hanging off a share button. Ordering is
    /// pinned (`.displayInline` inside a fixed-order parent at the call site) so the
    /// list reads top-to-bottom exactly as `rows` builds it, whichever edge of the
    /// screen the popover opens toward.
    public static func menu(rows: [Row]) -> UIMenu {
        UIMenu(children: rows.map(menuElement(for:)))
    }

    private static func menuElement(for row: Row) -> UIMenuElement {
        guard row.children.isEmpty else {
            return UIMenu(
                title: row.title, image: UIImage(systemName: row.systemImage),
                children: row.children.map(menuElement(for:)))
        }
        return UIAction(title: row.title, image: UIImage(systemName: row.systemImage)) { _ in
            row.action()
        }
    }

    private let rows: [Row]
    private let sheetTitle: String

    public init(rows: [Row], title: String = L10n.string("Share")) {
        self.rows = rows
        self.sheetTitle = title
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
    public static func present(
        from presenter: UIViewController, rows: [Row], title: String = L10n.string("Share")
    ) {
        presenter.present(ReaderShareSheet(rows: rows, title: title), animated: true)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        let titleLabel = UILabel()
        titleLabel.text = sheetTitle
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
        let row = rows[sender.tag]
        // Dismiss first so whatever comes next can present on the original
        // presenter without an "already presenting" conflict — which is also why
        // a submenu row has to capture that presenter before dismissing.
        guard row.children.isEmpty else {
            let presenter = presentingViewController
            let children = row.children
            let title = row.title
            dismiss(animated: true) {
                guard let presenter else { return }
                Self.present(from: presenter, rows: children, title: title)
            }
            return
        }
        let action = row.action
        dismiss(animated: true) { action() }
    }
}
