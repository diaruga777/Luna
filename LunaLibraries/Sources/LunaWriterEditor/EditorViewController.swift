//
//  EditorViewController.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage
import LunaWriterText

public protocol EditorViewControllerDelegate: AnyObject {
    func editorRequestsNotesPanel(_ editor: EditorViewController)
    func editorDidUpdateDocument(_ editor: EditorViewController, document: WriterDocument)
}

/// The sheet, on screen.
///
/// It assembles the text stack for one `DocumentSession`: the storage and its
/// layout attributes, the rendering layers over the viewport, Focus, the "@"
/// overlay, the related-note strip and the counts. The read-along overlay is
/// installed from outside, as a layer plus a passthrough host view.
public final class EditorViewController: UIViewController {

    // MARK: - Public

    public weak var delegate: EditorViewControllerDelegate?

    public let session: DocumentSession
    public let environment: EditorEnvironment

    public private(set) lazy var textView = WriterTextView(
        metrics: metrics, textStorage: session.storage)

    /// Where a read-along band or HUD is drawn. It takes no touches.
    public let readAlongHost = PassthroughView()

    public var sentenceGeometry: SentenceGeometryProvider { geometry }

    public init(session: DocumentSession, environment: EditorEnvironment) {
        self.session = session
        self.environment = environment
        metrics = EditorMetrics(settings: environment.settings)
        mention = MentionController(
            noteIndex: environment.noteIndex, noteStore: environment.noteStore,
            documentID: session.document.id)
        related = RelatedNotesRanker(
            noteIndex: environment.noteIndex, documentID: session.document.id)
        focus = FocusModeController(
            mode: environment.settings.focusMode,
            typewriterScrolling: environment.settings.typewriterScrolling)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Parts

    private var metrics: EditorMetrics
    private let mention: MentionController
    private let related: RelatedNotesRanker
    private let focus: FocusModeController
    private let keyboard = KeyboardFrameObserver()
    private let accessoryBar = EditorAccessoryBar()
    private let relatedStrip = RelatedNoteStripView()
    private let statisticsBar = StatisticsBarView()
    private let overlay = MentionOverlayView()
    private var peekCard: NotePeekCardView?

    private lazy var composer = RenderingAttributeComposer(
        layoutManager: textView.textLayoutManager, storage: session.storage)
    private lazy var geometry = SentenceGeometryProvider(
        layoutManager: textView.textLayoutManager, storage: session.storage)
    private lazy var posService = POSTaggingService()
    private lazy var markupLayer = MarkupLayer(model: session.storage.model)
    private lazy var syntaxLayer = SyntaxColourLayer(service: posService, storage: session.storage)
    private lazy var authorshipLayer = AuthorshipLayer(provider: session.authorship)
    private lazy var focusLayer = FocusLayer(provider: focus)
    private lazy var annotationLayer = AnnotationLayer(provider: session)
    private lazy var streamer = StreamingTextInserter(textView: textView)

    private var statisticsTimer: Timer?
    private var pendingEdit: (range: NSRange, replacementLength: Int)?

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        buildHierarchy()
        wire()
        updateStatistics()
        composer.invalidate(nil)
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.applicationDidEnterBackground()
    }

    deinit {
        statisticsTimer?.invalidate()
        session.close()
    }

    private func buildHierarchy() {
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        readAlongHost.translatesAutoresizingMaskIntoConstraints = false
        readAlongHost.backgroundColor = .clear
        view.addSubview(readAlongHost)

        statisticsBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statisticsBar)

        overlay.isHidden = true
        view.addSubview(overlay)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: statisticsBar.topAnchor),
            readAlongHost.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            readAlongHost.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            readAlongHost.topAnchor.constraint(equalTo: textView.topAnchor),
            readAlongHost.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            statisticsBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            statisticsBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            statisticsBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        let accessory = UIStackView(arrangedSubviews: [relatedStrip, accessoryBar])
        accessory.axis = .vertical
        accessory.spacing = 0
        accessory.frame = CGRect(
            x: 0, y: 0, width: view.bounds.width,
            height: RelatedNoteStripView.height + EditorAccessoryBar.height)
        accessory.autoresizingMask = .flexibleWidth
        textView.inputAccessoryView = accessory
    }

    private func wire() {
        textView.delegate = self
        textView.actionDelegate = self
        textView.authorshipDataSource = session

        composer.viewportProvider = self
        composer.addLayer(markupLayer)
        composer.addLayer(syntaxLayer)
        composer.addLayer(authorshipLayer)
        composer.addLayer(focusLayer)
        composer.addLayer(annotationLayer)
        syntaxLayer.invalidator = composer
        syntaxLayer.isEnabled = environment.settings.syntaxColouring
        authorshipLayer.invalidator = composer
        authorshipLayer.isEnabled = environment.settings.showAuthorship
        focusLayer.invalidator = composer
        annotationLayer.invalidator = composer

        session.storage.addObserver(self)
        session.authorship.observer = self
        streamer.delegate = self

        mention.textView = textView
        mention.delegate = self
        overlay.delegate = self
        related.observer = self
        focus.delegate = self
        keyboard.observer = self
        accessoryBar.delegate = self
        accessoryBar.setFocusActive(focus.mode != .off)
        relatedStrip.delegate = self
        statisticsBar.delegate = self
    }

    // MARK: - Overlay layer

    /// Puts a layer above every editor layer, for the read-along band.
    public func installOverlayLayer(_ layer: RenderingAttributeLayer) {
        composer.addLayer(layer)
    }

    public func removeOverlayLayer() {
        composer.removeLayer(.reading)
    }

    /// Repaints the colours of a range, after an overlay layer changed.
    public func invalidateRendering(_ range: NSRange?) {
        composer.invalidate(range)
    }

    // MARK: - Navigation

    /// Selects the anchored text and brings it on screen.
    public func focus(on anchor: TextAnchor) {
        guard let range = TextAnchorResolver.resolve(anchor, in: session.storage.nsText) else { return }
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
        focus.selectionChanged(to: range, in: session.storage.nsText)
    }

    // MARK: - Settings

    /// Takes the current settings: font, width, focus mode, the two toggles.
    public func applySettings() {
        let settings = environment.settings
        metrics = EditorMetrics(settings: settings)
        textView.metrics = metrics
        session.storage.styler = LayoutAttributeStyler(
            metrics: metrics, font: ReaderFont(rawValue: settings.fontIdentifier ?? "") ?? .system)
        focus.mode = settings.focusMode
        focus.typewriterScrolling = settings.typewriterScrolling
        syntaxLayer.isEnabled = settings.syntaxColouring
        authorshipLayer.isEnabled = settings.showAuthorship
        accessoryBar.setFocusActive(focus.mode != .off)
        // The styler assignment above already restyles and repaints through
        // MarkdownTextStorageObserving when it actually changed; a second,
        // unconditional repaint here was pure duplication.
    }

    // MARK: - Statistics

    private func scheduleStatistics() {
        statisticsTimer?.invalidate()
        statisticsTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.updateStatistics()
        }
    }

    private func updateStatistics() {
        let stats = TextStatistics.measure(session.storage.nsText)
        statisticsBar.update(stats: stats, goal: session.document.goal)
    }

    // MARK: - Typewriter

    fileprivate func scrollCaretToTypewriterLine() {
        guard let selected = textView.selectedTextRange else { return }
        let caret = textView.caretRect(for: selected.end)
        let visible = textView.bounds.height - textView.adjustedContentInset.top
        let bottom = TypewriterScroller.bottomInset(visibleHeight: visible)
        if abs(textView.contentInset.bottom - bottom) > 1 {
            textView.contentInset.bottom = bottom
        }
        let offset = TypewriterScroller.verticalOffset(
            caret: caret, visibleHeight: textView.bounds.height,
            topInset: textView.adjustedContentInset.top,
            contentHeight: textView.contentSize.height, bottomInset: bottom)
        guard abs(textView.contentOffset.y - offset) > 1 else { return }
        UIView.animate(withDuration: TypewriterScroller.duration) {
            self.textView.contentOffset.y = offset
        }
    }

    // MARK: - Mention overlay

    fileprivate func updateOverlay() {
        guard mention.state.isActive, !mention.isPeeking else {
            overlay.isHidden = true
            return
        }
        overlay.update(rows: mentionRows(), highlightedIndex: mention.highlightedIndex)
        overlay.isHidden = false
        placeOverlay()
    }

    private func placeOverlay() {
        let caret = view.convert(mention.markerRect(), from: textView)
        let keyboardTop = keyboard.isVisible
            ? view.convert(keyboard.frame, from: nil).minY
            : 0
        overlay.place(anchoredTo: caret, in: view, keyboardTop: keyboardTop)
    }

    private func mentionRows() -> [MentionRow] {
        var rows = mention.results.map { hit -> MentionRow in
            let note = try? environment.noteStore.note(hit.noteID)
            let elsewhere = note.map { !$0.documentIDs.contains(session.document.id) } ?? false
            return MentionRow(
                noteID: hit.noteID,
                title: hit.snippet.isEmpty ? (note?.text ?? "") : hit.snippet,
                detail: elsewhere ? L10n.string("WriterEditor_mentionNoteFromAnotherSheet") : nil,
                symbolName: "note.text")
        }
        let query = mention.state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        rows.append(MentionRow(
            noteID: nil,
            title: query.isEmpty
                ? L10n.string("WriterEditor_mentionNewNote")
                : L10n.string("WriterEditor_mentionNewNoteNamed", query),
            symbolName: "plus.circle"))
        return rows
    }

    // MARK: - Key commands

    public override var canBecomeFirstResponder: Bool { true }

    public override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(toggleBold)),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(toggleItalic)),
            UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(insertLink)),
            UIKeyCommand(input: "f", modifierFlags: [.command, .shift], action: #selector(cycleFocusMode)),
        ]
        if mention.state.isActive {
            commands.append(contentsOf: [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(mentionUp)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(mentionDown)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(mentionCommit)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(mentionDismiss)),
            ])
        }
        return commands
    }

    @objc private func mentionUp() { mention.moveHighlight(by: -1); updateOverlay() }
    @objc private func mentionDown() { mention.moveHighlight(by: 1); updateOverlay() }
    @objc private func mentionCommit() { mention.commitHighlighted() }
    @objc private func mentionDismiss() { mention.dismiss() }

    @objc private func toggleBold() { apply(MarkdownEditingCommands.toggleWrap(textView.selectedRange, marker: "**", in: session.storage.nsText)) }
    @objc private func toggleItalic() { apply(MarkdownEditingCommands.toggleWrap(textView.selectedRange, marker: "*", in: session.storage.nsText)) }
    @objc private func insertLink() {
        let selection = textView.selectedRange
        apply(EditorMarkdownActions.insertLink(selection, in: session.storage.nsText))
        let caret = EditorMarkdownActions.linkDestinationCaret(after: selection)
        textView.selectedRange = NSRange(location: caret, length: 0)
    }

    @objc private func cycleFocusMode() {
        let next: FocusMode
        switch focus.mode {
        case .off: next = .sentence
        case .sentence: next = .paragraph
        case .paragraph: next = .off
        }
        environment.settings.focusMode = next
        focus.mode = next
        accessoryBar.setFocusActive(next != .off)
        composer.invalidate(nil)
    }

    /// Runs a Markdown command's edits through the text view, so the undo
    /// manager and authorship see them as ordinary typing.
    private func apply(_ edits: [TextEdit]) {
        for edit in edits {
            textView.replaceText(in: edit.range, with: edit.replacement)
        }
    }
}

// MARK: - UITextViewDelegate

extension EditorViewController: UITextViewDelegate {

    public func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
        pendingEdit = (range, (text as NSString).length)
        return mention.textView(textView, shouldChangeTextIn: range, replacementText: text)
    }

    public func textViewDidChange(_ textView: UITextView) {
        if let edit = pendingEdit {
            pendingEdit = nil
            session.textDidChange(
                edit: edit.range, replacementLength: edit.replacementLength, typedBy: .author)
        }
        mention.textViewDidChange(textView)
        updateOverlay()
        related.caretMoved(to: textView.selectedRange.location, in: session.storage.nsText)
        scheduleStatistics()
        delegate?.editorDidUpdateDocument(self, document: session.document)
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        mention.textViewDidChangeSelection(textView)
        focus.selectionChanged(to: textView.selectedRange, in: session.storage.nsText)
        related.caretMoved(to: textView.selectedRange.location, in: session.storage.nsText)
        updateOverlay()
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        focus.isKeyboardVisible = true
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        focus.editingEnded()
        mention.dismiss()
        try? session.save()
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        composer.invalidate(nil)
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        composer.invalidate(nil)
    }
}

// MARK: - RenderingViewportProviding

extension EditorViewController: RenderingViewportProviding {

    public var hasViewport: Bool {
        textView.textLayoutManager?.textViewportLayoutController.viewportRange != nil
    }

    public var renderingViewportRange: NSRange {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange
        else { return NSRange(location: 0, length: session.storage.length) }
        let location = contentManager.offset(
            from: contentManager.documentRange.location, to: viewport.location)
        let end = contentManager.offset(
            from: contentManager.documentRange.location, to: viewport.endLocation)
        return NSRange(location: location, length: max(0, end - location))
    }
}

// MARK: - MarkdownTextStorageObserving

extension EditorViewController: MarkdownTextStorageObserving {

    public func markdownTextStorage(_ storage: MarkdownTextStorage, didRescan range: NSRange) {
        syntaxLayer.invalidateTags(in: range)
        composer.invalidate(range)
    }
}

// MARK: - AuthorshipObserving

extension EditorViewController: AuthorshipObserving {

    public func authorshipTracker(_ tracker: AuthorshipTracker, didChange range: NSRange) {
        composer.invalidate(range.length == Int.max ? nil : range)
    }
}

// MARK: - FocusModeControllerDelegate

extension EditorViewController: FocusModeControllerDelegate {

    public func focusModeController(_ controller: FocusModeController, didChangeFocusRange range: NSRange?) {
        composer.invalidate(nil)
    }

    public func focusModeControllerRequestsTypewriterScroll(_ controller: FocusModeController) {
        scrollCaretToTypewriterLine()
    }
}

// MARK: - WriterTextViewActionDelegate

extension EditorViewController: WriterTextViewActionDelegate {

    public func writerTextView(
        _ textView: WriterTextView, didInsert text: String, as source: AuthorshipSpan.Source, in range: NSRange
    ) {
        session.recordInsertion(range, source: source)
        composer.invalidate(range)
    }

    public func writerTextView(_ textView: WriterTextView, markAsOwn range: NSRange) {
        session.authorship.markAsOwn(range)
    }

    public func writerTextView(_ textView: WriterTextView, addNoteAt range: NSRange) {
        delegate?.editorRequestsNotesPanel(self)
    }
}

// MARK: - MentionControllerDelegate

extension EditorViewController: MentionControllerDelegate {

    public func mentionController(_ controller: MentionController, didChange state: MentionState) {
        updateOverlay()
    }

    public func mentionController(_ controller: MentionController, didUpdate results: [NoteHit], query: String) {
        updateOverlay()
    }

    public func mentionController(_ controller: MentionController, didRequestPeek note: WriterNote) {
        overlay.isHidden = true
        let sheet = note.documentIDs.contains(session.document.id) ? session.document.title : nil
        let card = NotePeekCardView(note: note, sheetName: sheet)
        card.delegate = self
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.widthAnchor.constraint(
                lessThanOrEqualToConstant: min(MentionOverlayView.maximumWidth, view.bounds.width - 32)),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        peekCard = card
    }

    public func mentionController(
        _ controller: MentionController, didCreate note: WriterNote, from markerRect: CGRect
    ) {
        let from = view.convert(markerRect, from: textView)
        let target = CGPoint(x: view.bounds.maxX - 40, y: view.safeAreaInsets.top + 20)
        NoteFlyInAnimator.fly(from: from, to: target, in: view)
    }

    public func mentionControllerDidEnd(_ controller: MentionController) {
        overlay.isHidden = true
        peekCard?.removeFromSuperview()
        peekCard = nil
    }
}

// MARK: - MentionOverlayViewDelegate

extension EditorViewController: MentionOverlayViewDelegate {

    public func mentionOverlay(_ overlay: MentionOverlayView, didSelectRowAt index: Int) {
        mention.highlightRow(index)
        mention.commitHighlighted()
    }

    public func mentionOverlayDidRequestDismiss(_ overlay: MentionOverlayView) {
        mention.dismiss()
    }
}

// MARK: - NotePeekCardViewDelegate

extension EditorViewController: NotePeekCardViewDelegate {

    public func notePeekCard(_ card: NotePeekCardView, didRequestEdit note: WriterNote) {
        delegate?.editorRequestsNotesPanel(self)
    }

    public func notePeekCardDidClose(_ card: NotePeekCardView) {
        card.removeFromSuperview()
        peekCard = nil
        mention.closePeek()
    }
}

// MARK: - RelatedNotesObserving

extension EditorViewController: RelatedNotesObserving {

    public func relatedNotesRanker(
        _ ranker: RelatedNotesRanker, didRank hits: [NoteHit], topMatch: NoteHit?
    ) {
        relatedStrip.show(noteID: topMatch?.noteID, snippet: topMatch?.snippet ?? "")
    }
}

// MARK: - RelatedNoteStripViewDelegate

extension EditorViewController: RelatedNoteStripViewDelegate {

    public func relatedNoteStrip(_ strip: RelatedNoteStripView, didSelect noteID: NoteID) {
        delegate?.editorRequestsNotesPanel(self)
    }
}

// MARK: - KeyboardFrameObserving

extension EditorViewController: KeyboardFrameObserving {

    public func keyboardFrameDidChange(_ frame: CGRect) {
        focus.isKeyboardVisible = keyboard.isVisible
        guard !overlay.isHidden else { return }
        placeOverlay()
    }
}

// MARK: - EditorAccessoryBarDelegate

extension EditorViewController: EditorAccessoryBarDelegate {

    public func editorAccessoryBar(_ bar: EditorAccessoryBar, didSelect action: EditorAccessoryAction) {
        let text = session.storage.nsText
        let selection = textView.selectedRange
        switch action {
        case .heading:
            apply(MarkdownEditingCommands.setHeading(1, paragraphAt: selection.location, in: text))
        case .bold:
            apply(MarkdownEditingCommands.toggleWrap(selection, marker: "**", in: text))
        case .italic:
            apply(MarkdownEditingCommands.toggleWrap(selection, marker: "*", in: text))
        case .list:
            apply(MarkdownEditingCommands.toggleList(.bullet, in: selection, of: text))
        case .task:
            apply(MarkdownEditingCommands.toggleTask(at: selection.location, in: text))
        case .quote:
            apply(EditorMarkdownActions.toggleQuote(selection, in: text))
        case .link:
            insertLink()
        case .code:
            apply(MarkdownEditingCommands.toggleWrap(selection, marker: "`", in: text))
        case .mention:
            textView.insertText("@")
        case .focus:
            cycleFocusMode()
        case .statistics:
            statisticsBarViewDidSelect(statisticsBar)
        }
    }
}

// MARK: - StatisticsBarViewDelegate

extension EditorViewController: StatisticsBarViewDelegate {

    public func statisticsBarViewDidSelect(_ view: StatisticsBarView) {
        let sheet = StatisticsSheet(stats: view.stats, goal: session.document.goal)
        sheet.modalPresentationStyle = .pageSheet
        present(sheet, animated: true)
    }
}

// MARK: - StreamingTextInserterDelegate

extension EditorViewController: StreamingTextInserterDelegate {

    public func streamingTextInserter(
        _ inserter: StreamingTextInserter, didInsert range: NSRange, as source: AuthorshipSpan.Source
    ) {
        session.recordInsertion(range, source: source)
        composer.invalidate(range)
    }

    public func streamingTextInserterDidFinish(_ inserter: StreamingTextInserter) {}
}

// MARK: - AI writing

extension EditorViewController {

    /// Asks the on-device model to carry on from the caret and types the
    /// answer in as `.ai` text.
    public func continueWriting() {
        guard let assistant = environment.aiAssistant, assistant.isAvailable else { return }
        let caret = textView.selectedRange.location
        let context = related.window(before: caret, in: session.storage.nsText)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let answer = try? await assistant.continueWriting(context: context), !answer.isEmpty else { return }
            self.streamer.insert(answer, as: .ai(model: assistant.modelIdentifier), at: caret)
        }
    }

    /// Rewrites the selection as `.ai` text.
    public func rewriteSelection(instruction: String? = nil) {
        guard let assistant = environment.aiAssistant, assistant.isAvailable else { return }
        let selection = textView.selectedRange
        guard selection.length > 0 else { return }
        let original = session.storage.nsText.substring(with: selection)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let answer = try? await assistant.rewrite(original, instruction: instruction),
                  !answer.isEmpty
            else { return }
            self.textView.replaceText(in: selection, with: "")
            self.streamer.insert(
                answer, as: .ai(model: assistant.modelIdentifier), at: selection.location)
        }
    }
}
