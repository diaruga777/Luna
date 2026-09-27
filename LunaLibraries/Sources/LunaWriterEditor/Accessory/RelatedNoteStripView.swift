//
//  RelatedNoteStripView.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaWriterModels

public protocol RelatedNoteStripViewDelegate: AnyObject {
    func relatedNoteStrip(_ strip: RelatedNoteStripView, didSelect noteID: NoteID)
}

/// One line above the keyboard naming the note that belongs beside what is
/// being written. It is there only while a match exists.
public final class RelatedNoteStripView: UIView {

    public static let height: CGFloat = 72

    public weak var delegate: RelatedNoteStripViewDelegate?

    private let button = UIButton(type: .system)
    private var noteID: NoteID?

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
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "note.text")
        configuration.imagePadding = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        configuration.titleLineBreakMode = .byWordWrapping
        button.configuration = configuration
        button.titleLabel?.numberOfLines = 3
        button.tintColor = EditorTheme.caret
        button.contentHorizontalAlignment = .leading
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    /// Shows one note, or nothing when `noteID` is nil.
    public func show(noteID: NoteID?, snippet: String) {
        self.noteID = noteID
        guard let noteID else {
            isHidden = true
            return
        }
        _ = noteID
        button.configuration?.attributedTitle = AttributedString(
            snippet,
            attributes: AttributeContainer([
                .font: UIFont.preferredFont(forTextStyle: .footnote),
                .foregroundColor: LunaColors.secondaryText,
            ]))
        isHidden = false
    }

    @objc private func tapped() {
        guard let noteID else { return }
        delegate?.relatedNoteStrip(self, didSelect: noteID)
    }
}
