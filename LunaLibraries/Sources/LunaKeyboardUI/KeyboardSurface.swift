import AudioToolbox
import LunaKeyboardCore
import LunaStorage
import UIKit
import UniformTypeIdentifiers

/// The same surface drives the extension and the containing app's tryout.
/// Only the host adapter owns the text document proxy.
public final class KeyboardSurface: UIView {
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
  private let prediction = KeyboardPrediction()
  private let suggestionScroll = UIScrollView()
  private let tools = UIButton(type: .system)
  private var suggestionButtons: [UIButton] = []
  private var suggestions: [KeyboardSuggestion] = []
  private var timer: Timer?
  private var shiftDate = Date.distantPast
  private var spaceDate = Date.distantPast
  private var reversal: (original: String, replacement: String)?
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
    tools.setImage(UIImage(systemName: "face.smiling"), for: .normal)
    tools.accessibilityLabel = "Emoji, shortcuts, GIFs and images"
    tools.accessibilityIdentifier = "keyboard.tools"
    tools.addAction(UIAction { [weak self] _ in self?.toggleTools() }, for: .touchUpInside)
    board.onKey = { [weak self] in self?.key($0) }
    board.onCursor = { [weak self] in
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
    refresh()
  }
  public func refresh() {
    timer?.invalidate()
    updateCasing()
    timer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: false) { [weak self] _ in
      self?.predict()
    }
  }
  public func releaseMemory() {
    timer?.invalidate()
    timer = nil
    board.reset()
    prediction.releaseMemory()
    reversal = nil
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
    if let reversal, context.hasSuffix(reversal.replacement) {
      suggestions.insert(
        .init(
          title: "↶ " + reversal.original, text: reversal.original, replacing: reversal.replacement),
        at: 0)
    }
    renderSuggestions()
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
        b.accessibilityLabel = suggestions[i].title
        b.accessibilityIdentifier = "keyboard.suggestion.\(i)"
      }
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
  private func apply(_ suggestion: KeyboardSuggestion) {
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
    if suggestion.kind == .word {
      reversal = (suggestion.replacing, output)
    } else {
      reversal = nil
    }
    refresh()
  }
  public func key(_ value: String) {
    if preferences.enabled("sound"), hasFullAccess { AudioServicesPlaySystemSound(1104) }
    if preferences.enabled("haptics"), hasFullAccess { haptic.impactOccurred(intensity: 0.45) }
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
      if let reversal, before().hasSuffix(reversal.replacement) {
        for _ in reversal.replacement { delete() }
        insert(reversal.original)
        self.reversal = nil
      } else {
        delete()
        reversal = nil
      }
      refresh()
      return
    }
    if value == " " || value == "return" {
      predict()
      if fieldAllowsAutocorrect, preferences.enabled("autocorrect"),
        let candidate = suggestions.first(where: { $0.autoApply }), !candidate.replacing.isEmpty,
        before().hasSuffix(candidate.replacing)
      {
        apply(candidate)
      }
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
        spaceDate = Date()
        if let previous = reversal {
          reversal = (previous.original, previous.replacement + separator)
        }
      }
      if board.page != 0 { board.page = 0 }
    } else {
      let text = board.uppercase ? value.uppercased() : value
      insert(board.textStyle.style(text))
      reversal = nil
      if !board.capsLock { board.uppercase = false }
    }
    refresh()
  }
  private func updateCasing() {
    guard !board.capsLock, preferences.enabled("autoCapitalize") else { return }
    let preceding = before()
    let trimmed = preceding.trimmingCharacters(in: .whitespaces)
    board.uppercase =
      preceding.isEmpty || preceding.hasSuffix("\n")
      || (preceding.last?.isWhitespace == true
        && [".", "!", "?"].contains(trimmed.last.map(String.init) ?? ""))
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
