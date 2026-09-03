//
//  WriterTextView.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels

/// Reads whatever the writer asked to paste. The system pasteboard is the
/// production witness; a test hands over a string of its own.
public protocol PasteboardReading: AnyObject {
    var pastedString: String? { get }
}

/// The system pasteboard, plain text first and an attributed copy flattened.
public final class SystemPasteboard: PasteboardReading {
    public init() {}

    public var pastedString: String? {
        let pasteboard = UIPasteboard.general
        if let string = pasteboard.string, !string.isEmpty { return string }
        guard let data = pasteboard.data(forPasteboardType: "public.rtf"),
              let attributed = try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        else { return nil }
        return attributed.string.isEmpty ? nil : attributed.string
    }
}

/// What the text view asks about the text under the selection.
public protocol WriterTextViewDataSource: AnyObject {
    /// True when any part of `range` was written by somebody other than the
    /// writer, which is what puts "Mark as mine" in the menu.
    func writerTextView(_ textView: WriterTextView, selectionTouchesForeignAuthorship range: NSRange) -> Bool
}

/// What the text view reports after the writer used one of its own actions.
public protocol WriterTextViewActionDelegate: AnyObject {
    func writerTextView(_ textView: WriterTextView, didInsert text: String, as source: AuthorshipSpan.Source, in range: NSRange)
    func writerTextView(_ textView: WriterTextView, markAsOwn range: NSRange)
    func writerTextView(_ textView: WriterTextView, addNoteAt range: NSRange)
}

/// The one text view Luna Writer edits in.
///
/// It is built with `usingTextLayoutManager: true` and never reads
/// `layoutManager`: touching that property silently drops the view back to
/// TextKit 1, and every rendering attribute this module applies would stop
/// arriving.
public final class WriterTextView: UITextView {

    public weak var actionDelegate: WriterTextViewActionDelegate?
    public weak var authorshipDataSource: WriterTextViewDataSource?

    public var pasteboard: PasteboardReading = SystemPasteboard()

    /// The model name recorded for text pasted as AI writing.
    public static let pasteboardModelIdentifier = "pasteboard"

    public var metrics: EditorMetrics {
        didSet {
            guard metrics != oldValue else { return }
            applyMetrics()
        }
    }

    private var appliedInsetWidth: CGFloat = -1

    public init(metrics: EditorMetrics, textStorage: NSTextStorage) {
        self.metrics = metrics
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let layoutManager = NSTextLayoutManager()
        layoutManager.textContainer = container
        let contentStorage = NSTextContentStorage()
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.textStorage = textStorage
        super.init(frame: .zero, textContainer: container)
        configure()
    }

    /// A view with a plain storage, for a caller that has no Markdown model.
    public convenience init(metrics: EditorMetrics = EditorMetrics()) {
        self.init(metrics: metrics, textStorage: NSTextStorage())
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    private func configure() {
        backgroundColor = .clear
        spellCheckingType = .no
        inlinePredictionType = .no
        autocorrectionType = .default
        smartQuotesType = .default
        smartDashesType = .default
        smartInsertDeleteType = .default
        autocapitalizationType = .sentences
        dataDetectorTypes = []
        isEditable = true
        isSelectable = true
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        textDragInteraction?.isEnabled = true
        tintColor = EditorTheme.caret
        textColor = EditorTheme.ink
        contentInsetAdjustmentBehavior = .always
        applyMetrics()
    }

    private func applyMetrics() {
        appliedInsetWidth = -1
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != appliedInsetWidth else { return }
        appliedInsetWidth = bounds.width
        textContainerInset = metrics.textContainerInset(forContainerWidth: bounds.width)
    }

    // MARK: - Editing helpers

    /// Replaces text through the input system, so the undo manager and the
    /// delegate see the change exactly as they would see typing.
    public func replaceText(in range: NSRange, with string: String) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = self.textRange(from: start, to: end)
        else { return }
        replace(textRange, withText: string)
    }

    /// Inserts text at the selection and reports it with an authorship source.
    public func insert(_ string: String, as source: AuthorshipSpan.Source) {
        let target = selectedRange
        guard delegate?.textView?(self, shouldChangeTextIn: target, replacementText: string) ?? true else { return }
        replaceText(in: target, with: string)
        let inserted = NSRange(location: target.location, length: (string as NSString).length)
        actionDelegate?.writerTextView(self, didInsert: string, as: source, in: inserted)
    }

    // MARK: - Paste

    public override func paste(_ sender: Any?) {
        guard let string = pasteboard.pastedString else {
            super.paste(sender)
            return
        }
        insert(string, as: .pasted)
    }

    @objc public func pasteAsAIText(_ sender: Any?) {
        guard let string = pasteboard.pastedString else { return }
        insert(string, as: .ai(model: Self.pasteboardModelIdentifier))
    }

    @objc public func markSelectionAsOwn(_ sender: Any?) {
        actionDelegate?.writerTextView(self, markAsOwn: selectedRange)
    }

    @objc public func addNoteHere(_ sender: Any?) {
        actionDelegate?.writerTextView(self, addNoteAt: selectedRange)
    }

    // MARK: - Menu

    /// The editor's own edit-menu items for a selection. "Mark as mine" is
    /// offered only where the selection touches somebody else's words.
    public func writerMenuElements(for range: NSRange) -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        if pasteboard.pastedString != nil {
            elements.append(UICommand(
                title: L10n.string("WriterEditor_menuPasteAsAI"),
                action: #selector(pasteAsAIText(_:))))
        }
        if authorshipDataSource?.writerTextView(self, selectionTouchesForeignAuthorship: range) == true {
            elements.append(UICommand(
                title: L10n.string("WriterEditor_menuMarkAsMine"),
                action: #selector(markSelectionAsOwn(_:))))
        }
        elements.append(UICommand(
            title: L10n.string("WriterEditor_menuAddNote"),
            action: #selector(addNoteHere(_:))))
        return elements
    }

    public override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let elements = writerMenuElements(for: selectedRange)
        guard !elements.isEmpty else { return }
        builder.insertChild(
            UIMenu(title: "", options: .displayInline, children: elements),
            atEndOfMenu: .root)
    }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(pasteAsAIText(_:)):
            return isEditable && pasteboard.pastedString != nil
        case #selector(markSelectionAsOwn(_:)):
            return authorshipDataSource?.writerTextView(self, selectionTouchesForeignAuthorship: selectedRange) == true
        case #selector(addNoteHere(_:)):
            return isEditable
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }
}
