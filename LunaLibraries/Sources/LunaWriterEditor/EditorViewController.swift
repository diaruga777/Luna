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
    /// The caret came to rest, or the keyboard went up or down. Reported
    /// when editing starts and ends and on each save, not per keystroke.
    func editorDidChangeEditingState(_ editor: EditorViewController, state: EditorEditingState)
}

extension EditorViewControllerDelegate {
    public func editorDidChangeEditingState(_ editor: EditorViewController, state: EditorEditingState) {}
}

/// Told when the text re-wraps or the page scrolls, so anything drawing
/// alongside the text (read-along's band and HUD) can follow it. Rotation,
/// a Split View resize, a font-size change and a hardware-keyboard toggle
/// all re-wrap without a storage edit, which is why this is a separate
/// witness from `MarkdownTextStorageObserving`.
public protocol EditorLayoutObserving: AnyObject {
    func editorDidRelayout(_ editor: EditorViewController)
    func editorDidScroll(_ editor: EditorViewController)
}

/// Adds edit-menu items the editor does not know about (read-along's
/// annotation kinds). Installed by the composition root per open sheet.
public protocol EditorMenuAugmenting: AnyObject {
    func editor(_ editor: EditorViewController, menuElementsFor selection: NSRange) -> [UIMenuElement]
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
    public weak var layoutObserver: EditorLayoutObserving?
    public weak var menuAugmenter: EditorMenuAugmenting?

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
    private let accessoryBar = EditorAccessoryBar()
    private let relatedStrip = RelatedNoteStripView()
    private lazy var accessoryContainer = UIStackView(arrangedSubviews: [relatedStrip, accessoryBar])
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

    /// A caret and keyboard state to put back, handed in before the text
    /// view exists. The keyboard waits for `viewDidAppear`.
    private var pendingRestoredState: EditorEditingState?
    private var statisticsTimer: Timer?
    private let statisticsQueue = DispatchQueue(label: "com.luna.writer.statistics", qos: .userInitiated)
    private var lastLayoutSize = CGSize(width: -1, height: -1)
    private var lastLayoutInset: UIEdgeInsets = UIEdgeInsets(top: -1, left: -1, bottom: -1, right: -1)
    /// The one AI request in flight. A second request cancels the first —
    /// there is only one caret, one selection, one place the answer lands.
    private var aiTask: Task<Void, Never>?

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        buildHierarchy()
        wire()
        updateStatistics()
        composer.invalidate(nil)
        if let pendingRestoredState { applyCaret(of: pendingRestoredState) }
    }

    /// A restored sheet takes the keyboard the writer left up; a sheet with
    /// nothing in it takes it because there is nothing else to do there.
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let state = pendingRestoredState {
            pendingRestoredState = nil
            // Applied again now the text view has its final size: a scroll
            // asked for before layout has nothing to scroll within.
            applyCaret(of: state)
            if state.isKeyboardVisible { textView.becomeFirstResponder() }
        } else if session.storage.length == 0 {
            textView.becomeFirstResponder()
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        relayoutIfNeeded()
        if !overlay.isHidden { placeOverlay() }
    }

    public override func viewWillTransition(
        to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        let anchor = firstVisibleCharacterPosition()
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.relayoutIfNeeded()
        }, completion: { [weak self] _ in
            guard let self, let anchor else { return }
            self.textView.scrollRangeToVisible(NSRange(location: anchor, length: 0))
        })
    }

    /// Re-wrap without a storage edit — rotation, a Split View resize, a
    /// font-size change, the keyboard changing the visible height — is
    /// invisible to `MarkdownTextStorageObserving`, so this is the one place
    /// that watches the text view's own geometry directly.
    private func relayoutIfNeeded() {
        let size = textView.bounds.size
        let inset = textView.textContainerInset
        guard size != lastLayoutSize || inset != lastLayoutInset else { return }
        lastLayoutSize = size
        lastLayoutInset = inset
        geometry.invalidate(nil)
        composer.invalidate(nil)
        layoutObserver?.editorDidRelayout(self)
        if focus.typewriterScrolling { scrollCaretToTypewriterLine() }
    }

    /// A stable point in the text under the middle of what's on screen right
    /// now, so a rotation can put the same words back where they were.
    private func firstVisibleCharacterPosition() -> Int? {
        let point = CGPoint(
            x: textView.bounds.midX,
            y: textView.contentOffset.y + textView.textContainerInset.top + 1)
        guard let position = textView.closestPosition(to: point) else { return nil }
        return textView.offset(from: textView.beginningOfDocument, to: position)
    }

    deinit {
        statisticsTimer?.invalidate()
        aiTask?.cancel()
    }

    /// Ends the session: cancels anything in flight and saves, snapshotting
    /// a sheet that changed. The host (`WriterEditorScreen`) calls this when
    /// the sheet is actually closing — `viewDidDisappear`/`deinit` no longer
    /// do this I/O themselves, since a view controller can disappear for
    /// reasons that have nothing to do with the sheet closing.
    public func close() {
        statisticsTimer?.invalidate()
        aiTask?.cancel()
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
            statisticsBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        accessoryContainer.axis = .vertical
        accessoryContainer.spacing = 0
        updateAccessoryContainer()
    }

    /// Recomputes the accessory's height from which of its two children are
    /// actually visible, and drops it entirely when neither is — the note
    /// strip only shows when a match exists, and the Markdown bar hides
    /// itself with a hardware keyboard attached; a fixed 80 pt used to sit
    /// above the keyboard regardless.
    private func updateAccessoryContainer() {
        let height = (relatedStrip.isHidden ? 0 : RelatedNoteStripView.height)
            + (accessoryBar.isHidden ? 0 : EditorAccessoryBar.height)
        guard height > 0 else {
            guard textView.inputAccessoryView != nil else { return }
            textView.inputAccessoryView = nil
            textView.reloadInputViews()
            return
        }
        accessoryContainer.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        accessoryContainer.autoresizingMask = .flexibleWidth
        guard textView.inputAccessoryView !== accessoryContainer else { return }
        textView.inputAccessoryView = accessoryContainer
        textView.reloadInputViews()
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
        session.delegate = self
        // The storage's own initial scan ran before this observer existed
        // (the session is built well before the view controller), so the
        // syntax layer never saw a rescan for the document it opens on.
        syntaxLayer.invalidateTags(in: NSRange(location: 0, length: session.storage.length))

        mention.textView = textView
        mention.delegate = self
        overlay.delegate = self
        related.observer = self
        focus.delegate = self
        accessoryBar.policy = environment.accessoryBarPolicy
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
    ///
    /// Setting `selectedRange` already drives `textViewDidChangeSelection`,
    /// which itself asks Focus to scroll when typewriter mode is on — an
    /// explicit `scrollRangeToVisible` on top of that would be a second,
    /// competing scroll for the one navigation.
    public func focus(on anchor: TextAnchor) {
        guard let range = TextAnchorResolver.resolve(anchor, in: session.storage.nsText) else { return }
        textView.selectedRange = range
        guard !focus.typewriterScrolling else { return }
        textView.scrollRangeToVisible(range)
    }

    // MARK: - Session state

    /// Where the caret rests and whether the keyboard is up. Read before the
    /// view loads it answers with the state waiting to be restored, so a
    /// snapshot taken at that moment does not overwrite it with zero.
    public var editingState: EditorEditingState {
        guard isViewLoaded else { return pendingRestoredState ?? EditorEditingState() }
        return EditorEditingState(
            caretLocation: textView.selectedRange.location,
            isKeyboardVisible: textView.isFirstResponder)
    }

    /// Puts the caret back where the last run left it. The keyboard follows
    /// in `viewDidAppear`, which is the earliest a text view can take it.
    public func restoreEditingState(_ state: EditorEditingState) {
        pendingRestoredState = state
        guard isViewLoaded else { return }
        applyCaret(of: state)
    }

    /// Clamps to the text as it is now: the file may have been edited
    /// elsewhere, or by an external change, since the caret was recorded.
    private func applyCaret(of state: EditorEditingState) {
        let location = min(max(0, state.caretLocation), session.storage.length)
        let range = NSRange(location: location, length: 0)
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
    }

    private func reportEditingState() {
        guard isViewLoaded else { return }
        delegate?.editorDidChangeEditingState(self, state: editingState)
    }

    // MARK: - Settings

    /// Takes the current settings: font, width, focus mode, the two toggles.
    public func applySettings() {
        let settings = environment.settings
        metrics = EditorMetrics(settings: settings)
        textView.metrics = metrics
        session.storage.styler = LayoutAttributeStyler(
            metrics: metrics, font: ReaderFont(rawValue: settings.fontIdentifier ?? "") ?? .system)
        setFocusMode(settings.focusMode)
        focus.typewriterScrolling = settings.typewriterScrolling
        if !settings.typewriterScrolling {
            // The extra bottom room typewriter mode holds open so the last
            // line can reach its position is never taken back on its own.
            textView.contentInset.bottom = 0
        }
        syntaxLayer.isEnabled = settings.syntaxColouring
        authorshipLayer.isEnabled = settings.showAuthorship
    }

    // MARK: - Statistics

    private func scheduleStatistics() {
        statisticsTimer?.invalidate()
        // .common: a scroll or another tracking-mode interaction must not
        // delay the count past the next keystroke's own 0.3s window.
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.updateStatistics()
        }
        RunLoop.current.add(timer, forMode: .common)
        statisticsTimer = timer
    }

    /// Copies and walks the whole document, so it runs off main with a
    /// revision guard: a slower count about text the writer already moved
    /// past must never overwrite a newer, correct one.
    private func updateStatistics() {
        let text = session.storage.string
        let revision = session.storage.revision
        let goal = session.document.goal
        statisticsQueue.async { [weak self] in
            let stats = TextStatistics.measure(text)
            DispatchQueue.main.async {
                guard let self, self.session.storage.revision == revision else { return }
                self.statisticsBar.update(stats: stats, goal: goal)
            }
        }
    }

    // MARK: - Typewriter

    fileprivate func scrollCaretToTypewriterLine() {
        // A programmatic scroll fighting the user's own finger reads as the
        // page fighting back; wait for the gesture to settle.
        guard !textView.isDragging, !textView.isDecelerating else { return }
        guard let selected = textView.selectedTextRange else { return }
        let caret = textView.caretRect(for: selected.end)
        let visibleHeight = textView.bounds.height
        let bottom = TypewriterScroller.bottomInset(visibleHeight: visibleHeight - textView.adjustedContentInset.top)
        if abs(textView.contentInset.bottom - bottom) > 1 {
            textView.contentInset.bottom = bottom
        }
        let offset = TypewriterScroller.verticalOffset(
            caret: caret, visibleHeight: visibleHeight,
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
        let keyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
        overlay.place(anchoredTo: caret, in: view, keyboardTop: keyboardTop)
    }

    /// Reads only `NoteHit` itself — no store read per row, per keystroke,
    /// while the overlay is up.
    private func mentionRows() -> [MentionRow] {
        var rows = mention.results.map { hit -> MentionRow in
            let elsewhere = !hit.documentIDs.contains(session.document.id)
            return MentionRow(
                noteID: hit.noteID,
                title: hit.snippet.isEmpty ? hit.noteText : hit.snippet,
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

    /// A fixed set, registered once: UIKit resolves a key command through the
    /// responder chain and asks `canPerformAction` before firing it, so the
    /// mention commands' availability belongs there, not in a rebuilt array —
    /// an unavailable command falls through to ordinary typing on its own.
    public override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(toggleBold)),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(toggleItalic)),
            UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(insertLink)),
            UIKeyCommand(input: "f", modifierFlags: [.command, .shift], action: #selector(cycleFocusMode)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(mentionUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(mentionDown)),
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(mentionCommit)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(mentionDismiss)),
            UIKeyCommand(
                input: "\r", modifierFlags: [.command, .alternate], action: #selector(continueWritingKeyCommand)),
            UIKeyCommand(
                input: "r", modifierFlags: [.command, .alternate], action: #selector(rewriteSelectionKeyCommand)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(indentKeyCommand)),
            UIKeyCommand(input: "\t", modifierFlags: [.shift], action: #selector(outdentKeyCommand)),
        ]
    }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(mentionUp), #selector(mentionDown),
             #selector(mentionCommit), #selector(mentionDismiss):
            return mention.state.isActive
        case #selector(continueWritingKeyCommand):
            return writerTextViewAIAssistantIsAvailable
        case #selector(rewriteSelectionKeyCommand):
            return writerTextViewAIAssistantIsAvailable && textView.selectedRange.length > 0
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    @objc private func indentKeyCommand() {
        apply(MarkdownEditingCommands.indent(textView.selectedRange, in: session.storage.nsText))
    }

    @objc private func outdentKeyCommand() {
        apply(MarkdownEditingCommands.outdent(textView.selectedRange, in: session.storage.nsText))
    }

    @objc private func continueWritingKeyCommand() { continueWriting() }
    @objc private func rewriteSelectionKeyCommand() { rewriteSelection() }

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
        setFocusMode(next)
    }

    /// The lit range is computed from the caret, so a mode switched on
    /// between keystrokes recomputes it now instead of waiting for the next
    /// caret move to show anything.
    private func setFocusMode(_ mode: FocusMode) {
        focus.mode = mode
        if mode != .off {
            focus.selectionChanged(to: textView.selectedRange, in: session.storage.nsText)
        }
        accessoryBar.setFocusActive(mode != .off)
        composer.invalidate(nil)
    }

    /// Runs a Markdown command's edits through the text view, so the undo
    /// manager and authorship see them as ordinary typing.
    /// A multi-line Markdown command (toggling a list, a quote) is several
    /// edits; grouped, one undo takes back the whole command instead of one
    /// line at a time.
    private func apply(_ edits: [TextEdit]) {
        guard !edits.isEmpty else { return }
        let undoManager = textView.undoManager
        let groups = edits.count > 1
        if groups { undoManager?.beginUndoGrouping() }
        for edit in edits {
            textView.replaceText(in: edit.range, with: edit.replacement)
        }
        if groups { undoManager?.endUndoGrouping() }
    }
}

// MARK: - UITextViewDelegate

extension EditorViewController: UITextViewDelegate {

    public func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
        guard mention.textView(textView, shouldChangeTextIn: range, replacementText: text) else { return false }
        // A bare Return in a list item or a blockquote continues it (or, on
        // an empty item, ends the list) instead of just breaking the line.
        if range.length == 0, text == "\n",
           let edits = MarkdownEditingCommands.continueList(onReturnAt: range.location, in: session.storage.nsText) {
            apply(edits)
            return false
        }
        return true
    }

    public func textViewDidChange(_ textView: UITextView) {
        mention.textViewDidChange(textView)
        updateOverlay()
        related.caretMoved(to: textView.selectedRange.location, in: session.storage.nsText)
        scheduleStatistics()
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        mention.textViewDidChangeSelection(textView)
        focus.selectionChanged(to: textView.selectedRange, in: session.storage.nsText)
        related.caretMoved(to: textView.selectedRange.location, in: session.storage.nsText)
        updateOverlay()
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        focus.isComposing = true
        reportEditingState()
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        focus.editingEnded()
        mention.dismiss()
        session.save()
        reportEditingState()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !overlay.isHidden {
            placeOverlay()
        }
        layoutObserver?.editorDidScroll(self)
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
        layoutObserver?.editorDidRelayout(self)
    }
}

// MARK: - AuthorshipObserving

extension EditorViewController: AuthorshipObserving {

    public func authorshipTracker(_ tracker: AuthorshipTracker, didChange range: NSRange?) {
        composer.invalidate(range)
    }
}

// MARK: - DocumentSessionDelegate

extension EditorViewController: DocumentSessionDelegate {

    /// The autosave lands a second after a burst of typing stops, which is
    /// the caret's resting position — cheap enough to record, and often
    /// enough that a session snapshot is never more than a burst behind.
    public func documentSessionDidSave(_ session: DocumentSession) {
        statisticsBar.saveFailed = false
        delegate?.editorDidUpdateDocument(self, document: session.document)
        reportEditingState()
    }

    public func documentSession(_ session: DocumentSession, didFailToSave error: Error) {
        statisticsBar.saveFailed = true
    }

    public func documentSession(_ session: DocumentSession, didReanchorWithOrphans orphans: [Annotation]) {
        // The resolved-annotations set this composer paints from changed.
        composer.invalidate(nil)
    }

    /// The text was replaced out from under this text view — an external
    /// file change, or a snapshot restore. The undo stack refers to gone
    /// text and a mention query, if one was open, is about to point at
    /// something that no longer exists.
    public func documentSessionDidReceiveExternalChange(_ session: DocumentSession) {
        textView.undoManager?.removeAllActions()
        mention.dismiss()
        scheduleStatistics()
        delegate?.editorDidUpdateDocument(self, document: session.document)
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
        session.markAsOwn(range)
    }

    /// Anchors an annotation to the selection right away, so the mark shows
    /// under the right words the moment "Add note" is chosen; the panel is
    /// where the writer gives it something to say.
    public func writerTextView(_ textView: WriterTextView, addNoteAt range: NSRange) {
        let anchor = TextAnchorResolver.make(range: range, in: session.storage.nsText)
        session.add(Annotation(documentID: session.document.id, kind: .comment, source: .manual, anchor: anchor))
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
        updateAccessoryContainer()
    }
}

// MARK: - RelatedNoteStripViewDelegate

extension EditorViewController: RelatedNoteStripViewDelegate {

    public func relatedNoteStrip(_ strip: RelatedNoteStripView, didSelect noteID: NoteID) {
        delegate?.editorRequestsNotesPanel(self)
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

    public func editorAccessoryBarVisibilityDidChange(_ bar: EditorAccessoryBar) {
        updateAccessoryContainer()
    }
}

// MARK: - StatisticsBarViewDelegate

extension EditorViewController: StatisticsBarViewDelegate {

    public func statisticsBarViewDidSelect(_ view: StatisticsBarView) {
        presentStatisticsSheet()
    }

    /// The one statistics surface, reached from the counts bar and from the
    /// container's ⋯ menu alike.
    public func presentStatisticsSheet() {
        let sheet = StatisticsSheet(stats: statisticsBar.stats, goal: session.document.goal)
        sheet.modalPresentationStyle = .pageSheet
        present(sheet, animated: true)
    }
}

// MARK: - WriterTextViewActionDelegate — AI

extension EditorViewController {

    public var writerTextViewAIAssistantIsAvailable: Bool {
        environment.aiAssistant?.isAvailable == true
    }

    public func writerTextView(_ textView: WriterTextView, additionalMenuElementsFor range: NSRange) -> [UIMenuElement] {
        menuAugmenter?.editor(self, menuElementsFor: range) ?? []
    }

    public func writerTextViewContinueWriting(_ textView: WriterTextView) {
        continueWriting()
    }

    public func writerTextViewRewriteSelection(_ textView: WriterTextView) {
        rewriteSelection()
    }
}

// MARK: - AI writing

extension EditorViewController {

    /// Asks the on-device model to carry on from the caret and types the
    /// answer in as `.ai` text.
    ///
    /// The document's revision is captured before the await and checked
    /// after: an edit anywhere while the model was generating means the
    /// context it answered about is gone, so the answer is dropped rather
    /// than typed in at a caret position that no longer means what it did.
    public func continueWriting() {
        guard let assistant = environment.aiAssistant, assistant.isAvailable else { return }
        let caret = textView.selectedRange.location
        let context = related.window(before: caret, in: session.storage.nsText)
        let revision = session.storage.revision
        aiTask?.cancel()
        aiTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let answer = try? await assistant.continueWriting(context: context), !answer.isEmpty else { return }
            guard !Task.isCancelled, self.session.storage.revision == revision else { return }
            self.textView.selectedRange = NSRange(location: caret, length: 0)
            self.textView.insert(answer, as: .ai(model: assistant.modelIdentifier))
        }
    }

    /// Rewrites the selection as `.ai` text. The same revision guard as
    /// `continueWriting` protects text typed while generation was running.
    /// The complete answer replaces the selection in one undoable operation;
    /// a timer must not keep inserting fragments after the writer moves on.
    public func rewriteSelection(instruction: String? = nil) {
        guard let assistant = environment.aiAssistant, assistant.isAvailable else { return }
        let selection = textView.selectedRange
        guard selection.length > 0 else { return }
        let original = session.storage.nsText.substring(with: selection)
        let revision = session.storage.revision
        aiTask?.cancel()
        aiTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let answer = try? await assistant.rewrite(original, instruction: instruction),
                  !answer.isEmpty
            else { return }
            guard !Task.isCancelled, self.session.storage.revision == revision else { return }
            self.textView.selectedRange = selection
            self.textView.insert(answer, as: .ai(model: assistant.modelIdentifier))
        }
    }
}
