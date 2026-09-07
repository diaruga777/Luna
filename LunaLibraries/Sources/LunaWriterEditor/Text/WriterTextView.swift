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
    /// Whether the pasteboard holds anything text-shaped, checked without
    /// reading its content: a `.string` read outside an actual paste raises
    /// the system's "would like to paste from" prompt.
    var hasStrings: Bool { get }
}

/// The system pasteboard, plain text first and an attributed copy flattened.
public final class SystemPasteboard: PasteboardReading {
    public init() {}

    public var hasStrings: Bool { UIPasteboard.general.hasStrings }

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

extension WriterTextViewActionDelegate {
    public func writerTextView(_ textView: WriterTextView, additionalMenuElementsFor range: NSRange) -> [UIMenuElement] { [] }
    public func writerTextView(_ textView: WriterTextView, didTapTaskMarkerAt offset: Int) {}
}

/// What the text view asks about the text under the selection.
public protocol WriterTextViewDataSource: AnyObject {
    /// The document's current length, so the text view never has to read
    /// `textStorage` (which silently drops a TextKit-2 view back to TextKit 1).
    var documentLength: Int { get }
    /// True when any part of `range` was written by somebody other than the
    /// writer, which is what puts "Mark as mine" in the menu.
    func writerTextView(_ textView: WriterTextView, selectionTouchesForeignAuthorship range: NSRange) -> Bool
}

/// What the text view reports after the writer used one of its own actions.
public protocol WriterTextViewActionDelegate: AnyObject {
    /// Items another tier adds to the edit menu for `range` — read-along's
    /// "Annotate" submenu. The default adds nothing.
    func writerTextView(_ textView: WriterTextView, additionalMenuElementsFor range: NSRange) -> [UIMenuElement]
    func writerTextView(_ textView: WriterTextView, didInsert text: String, as source: AuthorshipSpan.Source, in range: NSRange)
    func writerTextView(_ textView: WriterTextView, markAsOwn range: NSRange)
    func writerTextView(_ textView: WriterTextView, addNoteAt range: NSRange)
    /// A tap landed on the checkbox painted for the task item at `offset`.
    func writerTextView(_ textView: WriterTextView, didTapTaskMarkerAt offset: Int)
    /// Whether the on-device assistant is here at all, which is what gates
    /// "Continue writing" and "Rewrite selection" in the edit menu.
    var writerTextViewAIAssistantIsAvailable: Bool { get }
    func writerTextViewContinueWriting(_ textView: WriterTextView)
    func writerTextViewRewriteSelection(_ textView: WriterTextView)
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

    /// Reads the pasteboard and says what authorship the text earns.
    public let pasteInterceptor = PasteInterceptor()

    public var pasteboard: PasteboardReading {
        get { pasteInterceptor.pasteboard }
        set { pasteInterceptor.pasteboard = newValue }
    }

    public var metrics: EditorMetrics {
        didSet {
            guard metrics != oldValue else { return }
            fragmentProvider?.metrics = metrics
            applyMetrics()
        }
    }

    /// Paints what a collapsed Markdown marker left behind, and answers where
    /// a task item's checkbox is. Absent for a plain storage with no
    /// Markdown model.
    public let fragmentProvider: WriterLayoutFragmentProvider?

    private var appliedInsetWidth: CGFloat = -1
    private let taskMarkerGate = TaskMarkerTapGate()
    private var pendingTaskMarker: Int?

    public init(metrics: EditorMetrics, textStorage: NSTextStorage) {
        self.metrics = metrics
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let layoutManager = NSTextLayoutManager()
        layoutManager.textContainer = container
        let contentStorage = NSTextContentStorage()
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.textStorage = textStorage
        let provider = (textStorage as? MarkdownTextStorage).map {
            WriterLayoutFragmentProvider(storage: $0, metrics: metrics)
        }
        fragmentProvider = provider
        layoutManager.delegate = provider
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
        // Off: it also removes the predictive bar, so the keyboard stands at
        // its own height.
        autocorrectionType = .no
        smartQuotesType = .default
        smartDashesType = .default
        smartInsertDeleteType = .default
        autocapitalizationType = .sentences
        dataDetectorTypes = []
        isEditable = true
        isSelectable = true
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        tintColor = EditorTheme.caret
        // `textColor` recolours every character already in the storage; the
        // document loads with its own per-character colours from the styler,
        // so newly typed text gets its default through `typingAttributes`.
        typingAttributes[.foregroundColor] = EditorTheme.ink
        contentInsetAdjustmentBehavior = .always
        installTaskMarkerTap()
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
    ///
    /// `replaceText(in:with:)` already routes through `replace(_:withText:)`,
    /// which asks the delegate's `shouldChangeTextIn` itself; a second ask
    /// here would only repeat that answer.
    public func insert(_ string: String, as source: AuthorshipSpan.Source) {
        let target = selectedRange
        replaceText(in: target, with: string)
        let inserted = NSRange(location: target.location, length: (string as NSString).length)
        actionDelegate?.writerTextView(self, didInsert: string, as: source, in: inserted)
    }

    // MARK: - Task marker

    /// A tap in a task item's gutter ticks its box.
    ///
    /// Two ordering facts shape this. The recogniser must run BESIDE the text
    /// view's own tap, not instead of it — measured on iOS 26.2, a second tap
    /// recogniser takes caret placement away even when it fails every touch,
    /// so the gate allows simultaneous recognition. And the text view's tap
    /// reveals the line's raw source before any recogniser reaches its
    /// action, so the hit is decided at touch DOWN and remembered.
    private func installTaskMarkerTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTaskMarkerTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = taskMarkerGate
        taskMarkerGate.textView = self
        addGestureRecognizer(tap)
    }

    /// Remembers what a touch landed on, and says whether it was a checkbox.
    func beginTaskMarkerTracking(at point: CGPoint) -> Bool {
        pendingTaskMarker = taskMarkerOffset(at: point)
        return pendingTaskMarker != nil
    }

    @objc private func handleTaskMarkerTap(_ recognizer: UITapGestureRecognizer) {
        guard let offset = pendingTaskMarker else { return }
        pendingTaskMarker = nil
        actionDelegate?.writerTextView(self, didTapTaskMarkerAt: offset)
    }

    /// The character offset to toggle for a tap, or nil when the tap missed
    /// every painted checkbox.
    func taskMarkerOffset(at point: CGPoint) -> Int? {
        guard let provider = fragmentProvider, let position = closestPosition(to: point) else { return nil }
        let offset = self.offset(from: beginningOfDocument, to: position)
        let containerX = point.x - textContainerInset.left
        guard provider.hitsTaskMarker(at: offset, containerX: containerX) else { return nil }
        return offset
    }

    // MARK: - Paste

    public override func paste(_ sender: Any?) {
        // No text on the pasteboard the interceptor understands: nothing to
        // insert. `super.paste` would otherwise drop an attachment character
        // (an image, a file) into the `.md` file for a glyph that never draws.
        guard let pasted = pasteInterceptor.pasted() else { return }
        insert(pasted.text, as: pasted.source)
    }

    @objc public func pasteAsAIText(_ sender: Any?) {
        guard let pasted = pasteInterceptor.pastedAsAIText() else { return }
        insert(pasted.text, as: pasted.source)
    }

    @objc public func markSelectionAsOwn(_ sender: Any?) {
        actionDelegate?.writerTextView(self, markAsOwn: selectedRange)
    }

    @objc public func addNoteHere(_ sender: Any?) {
        actionDelegate?.writerTextView(self, addNoteAt: selectedRange)
    }

    @objc public func continueWritingWithAI(_ sender: Any?) {
        actionDelegate?.writerTextViewContinueWriting(self)
    }

    @objc public func rewriteSelectionWithAI(_ sender: Any?) {
        actionDelegate?.writerTextViewRewriteSelection(self)
    }

    // MARK: - Menu

    /// The editor's own edit-menu items for a selection. "Mark as mine" is
    /// offered only where the selection touches somebody else's words;
    /// "Rewrite selection" only where there is one.
    public func writerMenuElements(for range: NSRange) -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        if pasteInterceptor.hasText {
            elements.append(UICommand(
                title: L10n.string("WriterEditor_menuPasteAsAI"),
                action: #selector(pasteAsAIText(_:))))
        }
        if authorshipDataSource?.writerTextView(self, selectionTouchesForeignAuthorship: range) == true {
            elements.append(UICommand(
                title: L10n.string("WriterEditor_menuMarkAsMine"),
                action: #selector(markSelectionAsOwn(_:))))
        }
        if actionDelegate?.writerTextViewAIAssistantIsAvailable == true {
            elements.append(UICommand(
                title: L10n.string("WriterEditor_menuContinueWriting"),
                action: #selector(continueWritingWithAI(_:))))
            if range.length > 0 {
                elements.append(UICommand(
                    title: L10n.string("WriterEditor_menuRewriteSelection"),
                    action: #selector(rewriteSelectionWithAI(_:))))
            }
        }
        elements.append(UICommand(
            title: L10n.string("WriterEditor_menuAddNote"),
            action: #selector(addNoteHere(_:))))
        elements += actionDelegate?.writerTextView(self, additionalMenuElementsFor: range) ?? []
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
            return isEditable && pasteInterceptor.hasText
        case #selector(markSelectionAsOwn(_:)):
            return authorshipDataSource?.writerTextView(self, selectionTouchesForeignAuthorship: selectedRange) == true
        case #selector(addNoteHere(_:)):
            return isEditable
        case #selector(continueWritingWithAI(_:)):
            return isEditable && actionDelegate?.writerTextViewAIAssistantIsAvailable == true
        case #selector(rewriteSelectionWithAI(_:)):
            return isEditable && selectedRange.length > 0
                && actionDelegate?.writerTextViewAIAssistantIsAvailable == true
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }
}

/// Gates the task-marker tap and lets it run beside the text view's own
/// gestures, so ticking a box never costs the writer a caret placement.
private final class TaskMarkerTapGate: NSObject, UIGestureRecognizerDelegate {

    weak var textView: WriterTextView?

    /// Asked at touch down, which is the last moment the line's markers are
    /// still collapsed.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let textView else { return false }
        return textView.beginTaskMarkerTracking(at: touch.location(in: textView))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
