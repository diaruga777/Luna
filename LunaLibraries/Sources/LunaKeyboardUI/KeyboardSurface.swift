import LunaKeyboardCore
import LunaStorage
import UIKit
import UniformTypeIdentifiers

/// The same surface drives the extension and the containing app's tryout.
/// Only the host adapter owns the text document proxy.
public final class KeyboardSurface: UIView, UIInputViewAudioFeedback {
  public var before: () -> String = { "" }
  public var after: () -> String = { "" }
  public var insert: (String) -> Void = { _ in }
  public var delete: () -> Void = {}
  public var moveCursor: (Int) -> Void = { _ in }
  public var globe: ((UIView, UIEvent) -> Void)?
  public var heightChanged: ((CGFloat) -> Void)?
  public var hasFullAccess = false
  public var fieldAllowsAutocorrect = true
  private lazy var haptic = UIImpactFeedbackGenerator(style: .light)
  public var store: KeyboardStore?
  public var lexicon: [String: String] = [:]
  public var preferences = KeyboardPreferences()
  public let board = KeyboardBoardView()
  private var predictionStorage: KeyboardPrediction?
  private var prediction: KeyboardPrediction {
    if let predictionStorage { return predictionStorage }
    let value = KeyboardPrediction()
    predictionStorage = value
    return value
  }
  private let suggestionScroll = UIScrollView()
  private let tools = UIButton(type: .system)
  private var suggestionButtons: [UIButton] = []
  private var suggestions: [KeyboardSuggestion] = []
  private var timer: Timer?
  private var shiftDate = Date.distantPast
  private var spaceDate = Date.distantPast
  public var enableInputClicksWhenVisible: Bool { preferences.enabled("sound") }
  public var now: () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }
  public var fieldAllowsSmartPunctuation = true
  public var fieldAllowsCapitalization = true
  private var reversal: KeyboardCorrection?
  private var rejectedContext: String?
  private var lastContext = ""
  private var lastAfter = ""
  private var editedAt: TimeInterval = 0
  private let correctionWindow: TimeInterval = 2
  private let countdown = UIView()
  private var editingDepth = 0
  private var automaticShift = false
  private var capitalizedWord: String?
  private var capitalizedWords: [String] = []
  private var dragOriginal: String?
  private var dragAfter = ""
  private var dragRemoved = ""
  public var onEdit: (() -> Void)?
  private var panel: KeyboardToolsPanel?
  private var status: UILabel?
  public var boardHeight: CGFloat = 220 { didSet { setNeedsLayout() } }
  public var requiredHeight: CGFloat {
    boardHeight + 44 + (panel == nil ? 0 : preferences.enabled("compactSearch") ? 124 : 200)
  }
  public override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    addSubview(board)
    addSubview(suggestionScroll)
    addSubview(tools)
    countdown.backgroundColor = .systemBlue
    countdown.isUserInteractionEnabled = false
    suggestionScroll.addSubview(countdown)
    tools.setImage(UIImage(systemName: "face.smiling"), for: .normal)
    tools.accessibilityLabel = "Emoji, shortcuts, GIFs and images"
    tools.accessibilityIdentifier = "keyboard.tools"
    tools.addAction(UIAction { [weak self] _ in self?.toggleTools() }, for: .touchUpInside)
    board.onDeleteDrag = { [weak self] count in self?.updateDeleteDrag(count) }
    board.onDeleteDragEnd = { [weak self] in self?.finishDeleteDrag() }
    board.onKey = { [weak self] in self?.key($0) }
    board.onCursor = { [weak self] in
      self?.clearCorrection()
      self?.moveCursor($0)
      self?.refresh()
    }
    board.onGlobe = { [weak self] view, event in self?.globe?(view, event) }
    board.onSwipe = { [weak self] samples, centers in self?.swipe(samples, centers: centers) }
  }
  public required init?(coder: NSCoder) { fatalError("init(coder:)") }
  deinit { timer?.invalidate() }
  public override func layoutSubviews() {
    super.layoutSubviews()
    let extra = requiredHeight - boardHeight - 44
    tools.frame = CGRect(x: 0, y: 0, width: 40, height: 44)
    suggestionScroll.frame = CGRect(x: 40, y: 0, width: max(0, bounds.width - 40), height: 44)
    panel?.frame = CGRect(x: 0, y: 44, width: bounds.width, height: extra)
    board.frame = CGRect(x: 0, y: 44 + extra, width: bounds.width, height: boardHeight)
    layoutSuggestions()
  }
  public func reloadSettings() {
    if let values = try? store?.preferences() { preferences = KeyboardPreferences(values: values) }
    board.language = preferences.language
    board.blank = preferences.enabled("blankKeycaps")
    board.preview = preferences.enabled("characterPopup")
    board.swipeEnabled = preferences.enabled("swipeTyping")
    board.textStyle = preferences.style
    board.theme = preferences.theme
    refresh()
  }
  public func refresh() {
    timer?.invalidate()
    if editingDepth == 0 { synchronizeContext() }
    updateCasing()
    timer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: false) { [weak self] _ in
      self?.predict()
    }
  }
  public func releaseMemory() {
    timer?.invalidate()
    timer = nil
    board.reset()
    predictionStorage?.releaseMemory()
    predictionStorage = nil
    clearCorrection()
    capitalizedWord = nil
    capitalizedWords = []
    panel?.removeFromSuperview()
    panel = nil
    suggestions = []
    renderSuggestions()
    heightChanged?(requiredHeight)
  }
  private func predict() {
    guard panel == nil else { return }
    let context = before()
    suggestions = prediction.suggestions(
      before: context, preferences: preferences, store: store, lexicon: lexicon)
    if let reversal, reversal.canUndo(before: context, now: now()) {
      suggestions.insert(
        .init(
          title: "↶ " + reversal.original, text: reversal.original + reversal.suffix,
          replacing: reversal.replacement + reversal.suffix, kind: .shortcut),
        at: 0)
    }
    renderSuggestions()
    countdown.layer.removeAllAnimations()
    countdown.isHidden = true
    if fieldAllowsAutocorrect, preferences.enabled("autocorrect"), rejectedContext != context,
      let i = suggestions.firstIndex(where: { $0.autoApply }), i < suggestionButtons.count {
      let remaining = correctionWindow - (now() - editedAt)
      if remaining > 0 {
        let frame = suggestionButtons[i].frame
        countdown.frame = CGRect(x: frame.minX, y: 41, width: frame.width * remaining / correctionWindow, height: 3)
        countdown.isHidden = false
        UIView.animate(withDuration: remaining, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
          self.countdown.frame.size.width = 0
        }
      }
    }
  }
  private func renderSuggestions() {
    // Reuse at most twelve buttons. No per-keystroke observation graphs,
    // presenters, animation queues, or histories retained by the surface.
    while suggestionButtons.count < min(12, suggestions.count) {
      let b = UIButton(type: .system)
      b.titleLabel?.font = .systemFont(ofSize: 16)
      b.addAction(
        UIAction { [weak self, weak b] _ in
          guard let self, let b, let i = self.suggestionButtons.firstIndex(of: b),
            i < self.suggestions.count
          else { return }
          self.apply(self.suggestions[i])
        }, for: .touchUpInside)
      suggestionScroll.addSubview(b)
      suggestionButtons.append(b)
    }
    for (i, b) in suggestionButtons.enumerated() {
      b.isHidden = i >= suggestions.count
      if i < suggestions.count {
        b.setTitle(suggestions[i].title, for: .normal)
        b.accessibilityLabel = suggestions[i].accessibilityLabel
        b.accessibilityIdentifier = "keyboard.suggestion.\(i)"
      } else { b.setTitle(nil, for: .normal); b.accessibilityLabel = nil }
      b.tintColor = board.dark ? .white : .black
    }
    layoutSuggestions()
  }
  private func layoutSuggestions() {
    var x: CGFloat = 0
    let minWidth = max(70, suggestionScroll.bounds.width / 3)
    for (i, b) in suggestionButtons.enumerated() where !b.isHidden {
      let width = max(minWidth, min(220, b.intrinsicContentSize.width + 28))
      b.frame = CGRect(x: x, y: 0, width: width, height: 44)
      x += width
      b.accessibilityIdentifier = "keyboard.suggestion.\(i)"
    }
    suggestionScroll.contentSize = CGSize(width: x, height: 44)
  }
  private func apply(_ suggestion: KeyboardSuggestion, automatic: Bool = false) {
    editingDepth += 1
    defer { editingDepth -= 1 }
    if suggestion.kind == .media, let shortcut = suggestion.shortcut {
      copy(shortcut)
      return
    }
    let current = before()
    guard suggestion.replacing.isEmpty || current.hasSuffix(suggestion.replacing) else {
      refresh()
      return
    }
    for _ in suggestion.replacing { delete() }
    let output =
      (suggestion.kind == .word) ? board.textStyle.style(suggestion.text) : suggestion.text
    insert(output)
    if automatic {
      reversal = .init(original: suggestion.replacing, replacement: output, created: now())
    } else {
      reversal = nil
    }
    recordEdit()
    refresh()
  }
  public func key(_ value: String) {
    if value != "delete" { board.cancelRepeatingDelete() }
    synchronizeContext()
    editingDepth += 1
    defer { editingDepth -= 1 }
    if preferences.enabled("sound") { UIDevice.current.playInputClick() }
    if preferences.enabled("haptics"), hasFullAccess, value != "delete" || !before().isEmpty {
      haptic.impactOccurred(intensity: 0.45)
    }
    if value == "tab" { insert("\t"); recordEdit(); refresh(); return }
    if value == "123" {
      board.page = 1
      return
    }
    if value == "#+=" {
      board.page = 2
      return
    }
    if value == "ABC" {
      board.page = 0
      return
    }
    if value == "shift" {
      automaticShift = false
      let double = Date().timeIntervalSince(shiftDate) < 0.32
      board.capsLock = double && preferences.enabled("capsLock") && !board.capsLock
      board.uppercase = board.capsLock || !board.uppercase
      shiftDate = Date()
      return
    }
    if value == "styles" {
      toggleTools(styles: true)
      return
    }
    if let panel {
      if value == "delete" {
        panel.deleteSearch()
      } else if value == "return" {
        panel.searchNow()
      } else {
        panel.appendSearch(board.uppercase ? value.uppercased() : value)
      }
      if !board.capsLock { board.uppercase = false }
      return
    }
    if value == "delete" {
      if let reversal, reversal.canUndo(before: before(), now: now()) {
        for _ in reversal.replacement + reversal.suffix { delete() }
        // A word separator is removed, but punctuation is retained when undoing.
        let punctuation = reversal.suffix.filter { !$0.isWhitespace }
        insert(reversal.original + punctuation)
        self.reversal = nil
      } else {
        delete()
        reversal = nil
      }
      rejectedContext = before()
      recordEdit()
      refresh()
      return
    }
    if value == " " || value == "return" {
      rememberCapitalizedWord()
      applyPendingCorrection()
      if value == " ", preferences.enabled("periodShortcut"),
        Date().timeIntervalSince(spaceDate) < 0.4, before().hasSuffix(" "),
        before().dropLast().last?.isLetter == true
      {
        delete()
        insert(". ")
        spaceDate = .distantPast
      } else {
        let separator = value == "return" ? "\n" : " "
        insert(separator)
        if value == " " { lowercaseDisplacedSentenceWord() }
        spaceDate = Date()
        if let previous = reversal {
          reversal = previous
          reversal?.suffix += separator
        }
      }
      if board.page != 0 { board.page = 0 }
    } else {
      var text = board.uppercase ? value.uppercased() : value
      if text.count == 1, text.first?.isLetter == true {
        if automaticShift, value.first?.isLowercase == true, board.uppercase, !board.capsLock {
          capitalizedWord = text
        } else if let word = capitalizedWord, before().hasSuffix(word) {
          capitalizedWord = String((word + text).prefix(64))
        } else { capitalizedWord = nil }
      } else { rememberCapitalizedWord() }
      if fieldAllowsSmartPunctuation && preferences.enabled("smartPunctuation") {
        text = KeyboardEditing.smartQuote(text, before: before())
        if KeyboardEditing.isClosingPunctuation(text) {
          if before().hasSuffix(" "), before().dropLast().last?.isWhitespace == false {
            delete()
            if reversal?.suffix == " " { reversal?.suffix = "" }
          } else { applyPendingCorrection() }
          if reversal != nil { reversal?.suffix += text }
        } else { reversal = nil }
      } else { reversal = nil }
      insert(board.textStyle.style(text))
      rejectedContext = nil
      if !board.capsLock { board.uppercase = false }
    }
    recordEdit()
    refresh()
  }
  private func rememberCapitalizedWord() {
    if let word = capitalizedWord, word.count > 1, !capitalizedWords.contains(word) {
      capitalizedWords.append(word)
      capitalizedWords = Array(capitalizedWords.suffix(8))
    }
    capitalizedWord = nil
  }
  private func lowercaseDisplacedSentenceWord() {
    guard fieldAllowsCapitalization, preferences.enabled("autoCapitalize"),
      let word = capitalizedWords.first(where: {
        after().hasPrefix($0) && after().dropFirst($0.count).first?.isLetter != true
      }), let first = word.first, String(first).utf16.count == 1,
      before().dropLast().last?.isLetter == true else { return }
    // Change only a word this keyboard itself capitalized, in this session.
    // Names and existing pasted text are never inferred from capitalization alone.
    moveCursor(1)
    guard before().last == first else { moveCursor(-1); return }
    delete()
    insert(String(first).lowercased())
    moveCursor(-1)
    capitalizedWords.removeAll { $0 == word }
  }
  private func applyPendingCorrection() {
    guard fieldAllowsAutocorrect, preferences.enabled("autocorrect"),
      rejectedContext != before(), now() - editedAt < correctionWindow,
      after().first?.isLetter != true else { return }
    predict()
    if let candidate = suggestions.first(where: { $0.autoApply }), !candidate.replacing.isEmpty,
      before().hasSuffix(candidate.replacing) { apply(candidate, automatic: true) }
  }
  private func recordEdit() {
    lastContext = before()
    lastAfter = after()
    editedAt = now()
    onEdit?()
  }
  public func clearCorrection() {
    reversal = nil
    rejectedContext = nil
    countdown.layer.removeAllAnimations()
    countdown.isHidden = true
  }
  private func synchronizeContext() {
    if before() != lastContext || after() != lastAfter {
      rememberCapitalizedWord()
      clearCorrection()
      editedAt = now()
      lastContext = before()
      lastAfter = after()
    }
  }
  /// Drag preview uses reversible deletion because UITextDocumentProxy has no
  /// API for setting a selection. Moving right restores only our own removed text.
  public func updateDeleteDrag(_ count: Int) {
    editingDepth += 1
    defer { editingDepth -= 1 }
    if dragOriginal == nil {
      clearCorrection()
      dragOriginal = String(before().suffix(256))
      dragAfter = after()
      dragRemoved = ""
    }
    guard let original = dragOriginal, after() == dragAfter,
      before().hasSuffix(String(original.dropLast(dragRemoved.count))) else {
      finishDeleteDrag(); return
    }
    let removed = KeyboardEditing.deleteSuffix(original, count: count)
    guard removed != dragRemoved else { return }
    if removed.count > dragRemoved.count {
      for _ in 0..<(removed.count - dragRemoved.count) { delete() }
    } else { insert(String(dragRemoved.prefix(dragRemoved.count - removed.count))) }
    dragRemoved = removed
    if preferences.enabled("haptics"), hasFullAccess { haptic.impactOccurred(intensity: 0.45) }
    recordEdit()
    refresh()
  }
  public func finishDeleteDrag() { dragOriginal = nil; dragRemoved = "" }
  private func updateCasing() {
    guard !board.capsLock else { return }
    guard fieldAllowsCapitalization, preferences.enabled("autoCapitalize") else {
      if automaticShift { board.uppercase = false }
      automaticShift = false
      return
    }
    let preceding = before()
    let trimmed = preceding.trimmingCharacters(in: .whitespaces)
    automaticShift =
      preceding.isEmpty || preceding.hasSuffix("\n")
      || (preceding.last?.isWhitespace == true
        && [".", "!", "?"].contains(trimmed.last.map(String.init) ?? ""))
    board.uppercase = automaticShift
  }
  private func swipe(_ samples: [SwipeSample], centers: [Character: CGPoint]) {
    guard panel == nil else { return }
    let words = KeyboardSwipeDecoder.decode(
      samples, catalog: prediction.catalog, language: preferences.language, centers: centers)
    guard let first = words.first else { return }
    let word = board.uppercase ? first.prefix(1).uppercased() + first.dropFirst() : first
    let prefix = before().last.map { !$0.isWhitespace && $0.isLetter } == true ? " " : ""
    insert(prefix + board.textStyle.style(word))
    reversal = nil
    suggestions = words.dropFirst().map {
      .init(text: board.textStyle.style($0), replacing: board.textStyle.style(word))
    }
    renderSuggestions()
    if !board.capsLock { board.uppercase = false }
  }
  private func toggleTools(styles: Bool = false) {
    if panel != nil {
      panel?.removeFromSuperview()
      panel = nil
      refresh()
    } else {
      let p = KeyboardToolsPanel(
        catalog: prediction.catalog, store: store, fullAccess: hasFullAccess, styles: styles)
      p.onText = { [weak self] text in
        self?.insert(text)
        self?.closeTools()
      }
      p.onStyle = { [weak self] style in
        self?.board.textStyle = style
        try? self?.store?.setPreference("textStyle", value: style.rawValue)
        self?.closeTools()
      }
      p.onMedia = { [weak self] shortcut in self?.copy(shortcut) }
      p.onClose = { [weak self] in self?.closeTools() }
      addSubview(p)
      panel = p
    }
    heightChanged?(requiredHeight)
    setNeedsLayout()
  }
  private func closeTools() {
    panel?.removeFromSuperview()
    panel = nil
    heightChanged?(requiredHeight)
    setNeedsLayout()
    refresh()
  }
  private func copy(_ shortcut: KeyboardShortcut) {
    guard hasFullAccess else {
      showStatus("Enable Full Access to copy media.")
      return
    }
    guard
      let url = store?.fileURL(for: shortcut)
        ?? KeyboardResources.url(shortcut.text, extension: shortcut.kind == "gif" ? "gif" : "png")
    else { return }
    do {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= 8 * 1024 * 1024 else {
        showStatus("This file is too large for keyboard copying. Share it from Luna.")
        return
      }
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      UIPasteboard.general.setData(
        data,
        forPasteboardType: shortcut.kind == "gif" ? UTType.gif.identifier : UTType.image.identifier)
      showStatus("Copied. Touch and hold in your message, then Paste.")
    } catch { showStatus("Couldn’t copy this item.") }
  }
  private func showStatus(_ message: String) {
    if status == nil {
      let l = UILabel()
      l.font = .systemFont(ofSize: 12)
      l.numberOfLines = 2
      l.textAlignment = .center
      l.backgroundColor = .secondarySystemBackground
      addSubview(l)
      status = l
    }
    status?.frame = CGRect(x: 40, y: 0, width: bounds.width - 40, height: 44)
    status?.text = message
    status?.isHidden = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      self?.status?.isHidden = true
    }
  }
}
