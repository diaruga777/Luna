import LunaAppConfig
import LunaKeyboardCore
import LunaKeyboardUI
import LunaStorage
import UIKit

final class KeyboardViewController: UIInputViewController {
  private let surface = KeyboardSurface()
  private var height: NSLayoutConstraint?
  override func viewDidLoad() {
    super.viewDidLoad()
    inputView?.allowsSelfSizing = true
    surface.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(surface)
    NSLayoutConstraint.activate([
      surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      surface.topAnchor.constraint(equalTo: view.topAnchor),
      surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    let h = view.heightAnchor.constraint(equalToConstant: 264)
    h.priority = .init(999)
    h.isActive = true
    height = h
    surface.heightChanged = { [weak self] height in self?.height?.constant = height }
    surface.hostHandlesDoubleSpace = { KeyboardHostContext.writerIsActive() }
    surface.before = { [weak self] in self?.textDocumentProxy.documentContextBeforeInput ?? "" }
    surface.after = { [weak self] in self?.textDocumentProxy.documentContextAfterInput ?? "" }
    surface.hasSelection = { [weak self] in self?.textDocumentProxy.selectedText?.isEmpty == false }
    surface.insert = { [weak self] in self?.textDocumentProxy.insertText($0) }
    surface.delete = { [weak self] in self?.textDocumentProxy.deleteBackward() }
    surface.moveCursor = { [weak self] in
      self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: $0)
    }
    surface.board.onDismiss = { [weak self] in self?.dismissKeyboard() }
    surface.board.onNextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
    surface.globe = { [weak self] v, event in self?.handleInputModeList(from: v, with: event) }
    requestSupplementaryLexicon { [weak self] lexicon in
      var entries: [String: String] = [:]
      for entry in lexicon.entries.prefix(2000) {
        entries[entry.userInput.lowercased()] = entry.documentText
      }
      self?.surface.lexicon = entries
      self?.surface.refresh()
    }
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    surface.hasFullAccess = hasFullAccess
    if hasFullAccess {
      if surface.store == nil { surface.store = KeyboardStore(lowMemory: true) }
    } else { surface.store = nil }
    surface.reloadSettings()
    updateTraits()
  }
  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    updateTraits()
    surface.refresh()
  }
  override func selectionDidChange(_ textInput: UITextInput?) {
    super.selectionDidChange(textInput)
    surface.refresh()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let landscape = view.bounds.width > 600
    surface.boardHeight =
      traitCollection.userInterfaceIdiom == .pad ? (landscape ? 340 : 255) : (landscape ? 156 : 220)
    height?.constant = surface.requiredHeight
  }
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    surface.releaseMemory()
    let store = surface.store
    Task.detached(priority: .utility) { store?.trimMemory() }
  }
  override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning()
    surface.releaseMemory()
    let store = surface.store
    Task.detached(priority: .utility) { store?.trimMemory() }
  }
  private func updateTraits() {
    surface.board.dark =
      textDocumentProxy.keyboardAppearance == .dark
      || (textDocumentProxy.keyboardAppearance != .light
        && traitCollection.userInterfaceStyle == .dark)
    surface.board.needsGlobe = needsInputModeSwitchKey
    surface.board.keyboardType = textDocumentProxy.keyboardType ?? .default
    switch textDocumentProxy.returnKeyType ?? .default {
    case .go: surface.setDocumentReturnTitle("go")
    case .search, .google, .yahoo: surface.setDocumentReturnTitle("search")
    case .send: surface.setDocumentReturnTitle("send")
    case .done: surface.setDocumentReturnTitle("done")
    case .next: surface.setDocumentReturnTitle("next")
    case .join: surface.setDocumentReturnTitle("join")
    default: surface.setDocumentReturnTitle("return")
    }
    surface.fieldAllowsCapitalization = textDocumentProxy.autocapitalizationType != UITextAutocapitalizationType.none
      && textDocumentProxy.keyboardType != .URL && textDocumentProxy.keyboardType != .emailAddress
    surface.fieldAllowsSmartPunctuation = textDocumentProxy.smartQuotesType != .no
      && textDocumentProxy.keyboardType != .URL && textDocumentProxy.keyboardType != .emailAddress
    surface.fieldAllowsAutocorrect =
      textDocumentProxy.autocorrectionType != .no && textDocumentProxy.keyboardType != .URL
      && textDocumentProxy.keyboardType != .emailAddress
  }
}
