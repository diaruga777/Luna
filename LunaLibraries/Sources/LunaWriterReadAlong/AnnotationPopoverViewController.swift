//
//  AnnotationPopoverViewController.swift
//  LunaWriterReadAlong
//

import Foundation
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import UIKit

/// The reader of an annotation popover's edits.
public protocol AnnotationPopoverDelegate: AnyObject {
    func annotationPopover(
        _ popover: AnnotationPopoverViewController, didChange kind: Annotation.Kind)
    func annotationPopover(
        _ popover: AnnotationPopoverViewController, didEditComment text: String)
    func annotationPopoverDidDelete(_ popover: AnnotationPopoverViewController)
}

/// The card behind a tapped annotation: five colours, the comment's text when
/// there is one, and delete.
public final class AnnotationPopoverViewController: UIViewController, UITextViewDelegate {

    public weak var delegate: AnnotationPopoverDelegate?
    public private(set) var kind: Annotation.Kind
    /// The note's text, when the mark is a comment.
    public let commentText: String?

    private let swatches = UIStackView()
    private let textView = UITextView()
    private let deleteButton = UIButton(type: .system)
    private var swatchButtons: [Annotation.Kind: UIButton] = [:]

    public init(kind: Annotation.Kind, commentText: String?) {
        self.kind = kind
        self.commentText = commentText
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
        preferredContentSize = CGSize(width: 280, height: commentText == nil ? 120 : 220)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.secondaryBackground

        swatches.axis = .horizontal
        swatches.distribution = .fillEqually
        swatches.spacing = 8
        for candidate in Annotation.Kind.allCases {
            let button = UIButton(type: .system)
            button.backgroundColor = ReadAlongTheme.colour(for: candidate)
            button.layer.cornerRadius = 8
            button.layer.cornerCurve = .continuous
            button.accessibilityLabel = ReadAlongTheme.title(for: candidate)
            button.addTarget(self, action: #selector(swatchTapped(_:)), for: .touchUpInside)
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            swatchButtons[candidate] = button
            swatches.addArrangedSubview(button)
        }

        textView.delegate = self
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = LunaColors.tertiaryBackground
        textView.textColor = LunaColors.primaryText
        textView.layer.cornerRadius = 8
        textView.text = commentText ?? ""
        textView.isHidden = commentText == nil

        deleteButton.setTitle(L10n.string("WriterReadAlong_annotationDelete"), for: .normal)
        deleteButton.setTitleColor(LunaColors.errorAccent, for: .normal)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [swatches, textView, deleteButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: view.bottomAnchor, constant: -14),
        ])
        highlightSelectedSwatch()
    }

    private func highlightSelectedSwatch() {
        for (candidate, button) in swatchButtons {
            button.layer.borderWidth = candidate == kind ? 3 : 0
            button.layer.borderColor = LunaColors.primaryText.cgColor
        }
    }

    @objc private func swatchTapped(_ sender: UIButton) {
        guard let picked = swatchButtons.first(where: { $0.value === sender })?.key else { return }
        kind = picked
        highlightSelectedSwatch()
        delegate?.annotationPopover(self, didChange: picked)
    }

    @objc private func deleteTapped() {
        delegate?.annotationPopoverDidDelete(self)
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        delegate?.annotationPopover(self, didEditComment: textView.text)
    }
}
