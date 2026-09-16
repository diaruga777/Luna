//
//  CommandPaletteOverlayView.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels

public protocol CommandPaletteOverlayViewDelegate: AnyObject {
    func paletteOverlay(_ overlay: CommandPaletteOverlayView, didSelectRowAt index: Int)
    func paletteOverlayDidRequestDismiss(_ overlay: CommandPaletteOverlayView)
}

/// The panel that appears under the palette's marker.
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
    private let scrollView = UIScrollView()
    private var resultViews: [Int: UIView] = [:]
    private var placement: (viewport: CGRect, origin: CGPoint)?
    private var reservedHeight: CGFloat = 0
    public private(set) var isBelowAnchor = false
    private static let headerHeight: CGFloat = 32
    private var rows: [PaletteRow] = []
    private var highlighted: Int?
    private var needsHighlightReveal = false

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
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInsetAdjustmentBehavior = .never
        panel.contentView.addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: panel.contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        accessibilityIdentifier = "writer.commandPalette"
        rebuild()
    }

    // MARK: - Content

    public var rowCount: Int { rows.count }

    public func update(rows: [PaletteRow], highlightedIndex: Int?) {
        if rows != self.rows {
            self.rows = rows
            rebuild()
        }
        highlight(highlightedIndex)
    }

    /// Tints the row Return will run and shows the return arrow on it. nil
    /// clears both: Return types a newline.
    public func highlight(_ index: Int?) {
        needsHighlightReveal = needsHighlightReveal || highlighted != index
        highlighted = index
        for (position, view) in resultViews {
            let isHighlighted = position == index
            view.backgroundColor = isHighlighted ? EditorTheme.caret.withAlphaComponent(0.22) : .clear
            (view as? PaletteRowView)?.returnIcon.isHidden = !isHighlighted
            let button = (view as? PaletteRowView)?.button ?? (view as? UIButton)
            button?.accessibilityTraits = isHighlighted ? [.button, .selected] : [.button]
        }
    }

    private func revealHighlightIfNeeded() {
        guard needsHighlightReveal else { return }
        needsHighlightReveal = false
        guard let highlighted, let selected = resultViews[highlighted] else { return }
        layoutIfNeeded()
        if let strip = selected.superview?.superview as? UIScrollView, strip !== scrollView {
            strip.scrollRectToVisible(selected.convert(selected.bounds, to: strip), animated: false)
        }
        if highlighted == 0 {
            // Keep the cue visible with the best result, including when an
            // arrow key returns to it from further down the list.
            scrollView.setContentOffset(.zero, animated: false)
        } else {
            scrollView.scrollRectToVisible(selected.convert(selected.bounds, to: scrollView), animated: false)
        }
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resultViews.removeAll()
        needsHighlightReveal = true
        scrollView.setContentOffset(.zero, animated: false)

        let cue = UILabel()
        cue.text = L10n.string("WriterLibrary_settings_paletteRow")
        cue.font = UIFont.preferredFont(forTextStyle: .caption1)
        cue.textColor = EditorTheme.caret
        cue.accessibilityIdentifier = "writer.commandPalette.indicator"
        let header = UIView()
        header.addSubview(cue)
        cue.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            cue.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            cue.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -12),
            cue.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        stack.addArrangedSubview(header)
        for group in PaletteRow.displayGroups(in: rows) {
            if rows[group[0]].symbolCharacter != nil {
                stack.addArrangedSubview(makeSymbolStrip(indices: group))
            } else {
                let index = group[0]
                let view = makeRowView(rows[index], index: index)
                resultViews[index] = view
                stack.addArrangedSubview(view)
            }
        }
    }

    private func makeSymbolStrip(indices: [Int]) -> UIView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        let tiles = UIStackView()
        tiles.axis = .horizontal
        tiles.spacing = 4
        tiles.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(tiles)
        NSLayoutConstraint.activate([
            tiles.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            tiles.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            tiles.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            tiles.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            tiles.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        for index in indices {
            let button = UIButton(type: .system)
            button.setTitle(rows[index].symbolCharacter, for: .normal)
            button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .title2)
            button.setTitleColor(LunaColors.primaryText, for: .normal)
            button.accessibilityLabel = rows[index].title
            button.accessibilityIdentifier = "writer.commandPalette.result.\(index)"
            button.tag = index
            button.layer.cornerRadius = 8
            button.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.rowHeight).isActive = true
            tiles.addArrangedSubview(button)
            resultViews[index] = button
        }
        return scroll
    }

    private func makeRowView(_ row: PaletteRow, index: Int) -> UIView {
        let view = PaletteRowView()
        let button = view.button
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: row.symbolName)
        configuration.imagePadding = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        configuration.attributedTitle = AttributedString(
            row.title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " "),
            attributes: AttributeContainer([
                .font: UIFont.preferredFont(forTextStyle: .subheadline),
                .foregroundColor: LunaColors.primaryText,
            ]))
        configuration.titleAlignment = .leading
        configuration.titleLineBreakMode = .byTruncatingTail
        button.configuration = configuration
        button.titleLabel?.numberOfLines = 1
        button.accessibilityIdentifier = "writer.commandPalette.result.\(index)"
        button.contentHorizontalAlignment = .leading
        button.tintColor = EditorTheme.caret
        button.tag = index
        button.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.rowHeight).isActive = true
        if row.action == .none {
            button.isUserInteractionEnabled = false
            button.alpha = 0.7
        }
        return view
    }

    @objc private func rowTapped(_ sender: UIButton) {
        delegate?.paletteOverlay(self, didSelectRowAt: sender.tag)
    }

    // MARK: - Placement

    /// Only a new palette session or a viewport/keyboard change relocates
    /// the panel. Text reflow and typewriter scrolling cannot move its origin.
    public func resetPlacement() {
        placement = nil
        reservedHeight = 0
    }

    public func place(anchoredTo caret: CGRect, in container: UIView, keyboardTop: CGFloat) {
        let safe = container.bounds.inset(by: container.safeAreaInsets)
        let limit = min(safe.maxY, keyboardTop > 0 ? keyboardTop : safe.maxY) - Self.anchorGap
        let viewport = CGRect(x: safe.minX + 16, y: safe.minY,
                              width: max(1, safe.width - 32), height: max(1, limit - safe.minY))
        let column = min(Self.maximumWidth, viewport.width)
        if placement?.viewport != viewport {
            // Reserve room for the full set before results arrive, so changing
            // row counts never flips the panel across the query or keyboard.
            let maximumHeight = Self.headerHeight + 8 +
                CGFloat(CommandPaletteController.resultLimit + 1) * Self.rowHeight
            let above = max(0, caret.minY - Self.anchorGap - viewport.minY)
            let below = max(viewport.minY, caret.maxY + Self.anchorGap)
            let belowSpace = max(0, viewport.maxY - below)
            // Prefer above when it fits at least a result: wrapped query text
            // then grows away from the panel instead of underneath it.
            let useAbove = above >= Self.headerHeight + Self.rowHeight + 8 || above > belowSpace
            isBelowAnchor = !useAbove
            reservedHeight = max(1, min(maximumHeight, useAbove ? above : belowSpace))
            let top = useAbove ? max(viewport.minY, caret.minY - Self.anchorGap - reservedHeight) : below
            let left = min(max(viewport.minX, caret.minX - 8), viewport.maxX - column)
            placement = (viewport, CGPoint(x: left, y: top))
        }
        let contentHeight = stack.systemLayoutSizeFitting(
            CGSize(width: column, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height + 8
        frame = CGRect(origin: placement!.origin,
                       size: CGSize(width: column, height: min(contentHeight, reservedHeight)))
        revealHighlightIfNeeded()
    }

}

/// One concise row: the button carries an icon and title; the return arrow
/// at the trailing edge shows on the row Return runs.
final class PaletteRowView: UIView {
    let button = UIButton(type: .system)
    let returnIcon = UIImageView(image: UIImage(systemName: "return"))

    init() {
        super.init(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        returnIcon.translatesAutoresizingMaskIntoConstraints = false
        returnIcon.tintColor = LunaColors.secondaryText
        returnIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        returnIcon.isHidden = true
        addSubview(button)
        addSubview(returnIcon)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.trailingAnchor.constraint(equalTo: returnIcon.leadingAnchor, constant: -4),
            returnIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            returnIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            returnIcon.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
