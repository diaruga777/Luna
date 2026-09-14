//
//  CommandPaletteOverlayView.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels

/// One row of the "@" overlay.
public struct PaletteRow: Equatable {
    public var noteID: NoteID?
    public var title: String
    public var detail: String?
    public var symbolName: String

    public init(noteID: NoteID?, title: String, detail: String? = nil, symbolName: String) {
        self.noteID = noteID
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
    }
}

public protocol CommandPaletteOverlayViewDelegate: AnyObject {
    func paletteOverlay(_ overlay: CommandPaletteOverlayView, didSelectRowAt index: Int)
    func paletteOverlayDidRequestDismiss(_ overlay: CommandPaletteOverlayView)
}

/// The panel that appears under the "@".
///
/// It never becomes first responder: the writer keeps typing into the sheet
/// while it is up, and every key it handles arrives through the editor's own
/// key commands.
public final class CommandPaletteOverlayView: UIView {

    public static let maximumWidth: CGFloat = 360
    public static let rowHeight: CGFloat = 44
    /// The gap between the caret line and the panel.
    public static let anchorGap: CGFloat = 6

    public weak var delegate: CommandPaletteOverlayViewDelegate?

    private let panel = GlassStyle.focusPanel()
    private let stack = UIStackView()
    private var rows: [PaletteRow] = []
    private var highlighted = 0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override var canBecomeFirstResponder: Bool { false }

    private func build() {
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.layer.cornerRadius = 14
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        addSubview(panel)

        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -4),
        ])
    }

    // MARK: - Content

    public var rowCount: Int { rows.count }

    public func update(rows: [PaletteRow], highlightedIndex: Int) {
        if rows != self.rows {
            self.rows = rows
            rebuild()
        }
        highlight(highlightedIndex)
    }

    public func highlight(_ index: Int) {
        highlighted = index
        for (position, view) in stack.arrangedSubviews.enumerated() {
            view.backgroundColor = position == index
                ? EditorTheme.caret.withAlphaComponent(0.22)
                : .clear
        }
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            stack.addArrangedSubview(makeRowView(row, index: index))
        }
    }

    private func makeRowView(_ row: PaletteRow, index: Int) -> UIView {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: row.symbolName)
        configuration.imagePadding = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        configuration.attributedTitle = AttributedString(
            row.title,
            attributes: AttributeContainer([
                .font: UIFont.preferredFont(forTextStyle: .subheadline),
                .foregroundColor: LunaColors.primaryText,
            ]))
        if let detail = row.detail {
            configuration.attributedSubtitle = AttributedString(
                detail,
                attributes: AttributeContainer([
                    .font: UIFont.preferredFont(forTextStyle: .caption1),
                    .foregroundColor: LunaColors.tertiaryText,
                ]))
        }
        configuration.titleAlignment = .leading
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.tintColor = EditorTheme.caret
        button.tag = index
        button.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.rowHeight).isActive = true
        return button
    }

    @objc private func rowTapped(_ sender: UIButton) {
        delegate?.paletteOverlay(self, didSelectRowAt: sender.tag)
    }

    // MARK: - Placement

    /// Puts the panel under the "@", or above it when the keyboard would
    /// cover it. `caret` and `keyboard` are in `container` coordinates.
    public func place(anchoredTo caret: CGRect, in container: UIView, keyboardTop: CGFloat) {
        let column = min(Self.maximumWidth, container.bounds.width - 32)
        let height = max(Self.rowHeight, systemLayoutSizeFitting(
            CGSize(width: column, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height)

        let below = caret.maxY + Self.anchorGap
        let limit = keyboardTop > 0 ? keyboardTop : container.bounds.maxY
        let top = (below + height <= limit) ? below : max(0, caret.minY - Self.anchorGap - height)
        let left = min(max(16, caret.minX - 8), max(16, container.bounds.width - column - 16))
        frame = CGRect(x: left, y: top, width: column, height: height)
    }
}
