//
//  NotePeekCardView.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels

public protocol NotePeekCardViewDelegate: AnyObject {
    func notePeekCard(_ card: NotePeekCardView, didRequestEdit note: WriterNote)
    func notePeekCardDidClose(_ card: NotePeekCardView)
}

/// A note shown over the text.
///
/// Nothing in it is ever copied into the sheet: the card reads the note and
/// closes again (writer-app.md Q5).
public final class NotePeekCardView: UIView {

    public weak var delegate: NotePeekCardViewDelegate?

    public private(set) var note: WriterNote

    private let panel = GlassStyle.focusPanel()
    private let bodyLabel = UILabel()
    private let sheetLabel = UILabel()

    public init(note: WriterNote, sheetName: String?) {
        self.note = note
        super.init(frame: .zero)
        build(sheetName: sheetName)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override var canBecomeFirstResponder: Bool { false }

    private func build(sheetName: String?) {
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.layer.cornerRadius = 18
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        addSubview(panel)

        sheetLabel.text = sheetName ?? L10n.string("WriterEditor_peekNoSheet")
        sheetLabel.font = .preferredFont(forTextStyle: .caption1)
        sheetLabel.textColor = LunaColors.tertiaryText

        bodyLabel.text = note.text
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.textColor = LunaColors.primaryText
        bodyLabel.numberOfLines = 0

        let edit = UIButton(type: .system)
        edit.setTitle(L10n.string("WriterEditor_peekEdit"), for: .normal)
        edit.tintColor = EditorTheme.caret
        edit.addTarget(self, action: #selector(editTapped), for: .touchUpInside)

        let close = UIButton(type: .system)
        close.setTitle(L10n.string("WriterEditor_peekClose"), for: .normal)
        close.tintColor = LunaColors.secondaryText
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [edit, UIView(), close])
        buttons.axis = .horizontal
        buttons.spacing = 12

        let stack = UIStackView(arrangedSubviews: [sheetLabel, bodyLabel, buttons])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -14),
        ])
    }

    @objc private func editTapped() {
        delegate?.notePeekCard(self, didRequestEdit: note)
    }

    @objc private func closeTapped() {
        delegate?.notePeekCardDidClose(self)
    }
}
